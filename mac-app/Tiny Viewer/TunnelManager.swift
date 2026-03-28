import Foundation

enum TunnelStatus: Equatable {
    case stopped
    case starting
    case running(url: String)
    case failed(String)

    var url: String? {
        if case .running(let u) = self { return u }
        return nil
    }

    var label: String {
        switch self {
        case .stopped:           return "Stopped"
        case .starting:          return "Starting…"
        case .running(let url):  return url
        case .failed(let err):   return "Error: \(err)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@Observable
class TunnelManager {

    private(set) var status: TunnelStatus = .stopped
    var onURLDiscovered: ((String) -> Void)?
    var onTerminated: (() -> Void)?

    private var process: Process?
    private var buffer = ""

    // MARK: - Lifecycle

    func start() {
        guard case .stopped = status else { return }
        status = .starting
        buffer = ""

        guard let binary = findCloudflared() else {
            status = .failed("cloudflared not found — run: brew install cloudflared")
            return
        }

        let p = Process()
        p.executableURL = binary
        p.arguments = ["tunnel", "--url", "http://localhost:8080"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.buffer += chunk
                if let url = self.extractURL(from: self.buffer),
                   !self.status.isRunning {
                    self.status = .running(url: url)
                    self.onURLDiscovered?(url)
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                switch self.status {
                case .running:
                    self.status = .stopped
                    self.onTerminated?()
                case .starting:
                    self.status = .failed("Tunnel exited (code \(proc.terminationStatus))")
                default:
                    break
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        buffer  = ""
        status  = .stopped
    }

    // MARK: - Helpers

    private func findCloudflared() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to `which cloudflared`
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["cloudflared"]
        let out = Pipe()
        which.standardOutput = out
        try? which.run()
        which.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func extractURL(from text: String) -> String? {
        let pattern = "https://[a-zA-Z0-9][a-zA-Z0-9-]*\\.trycloudflare\\.com"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
