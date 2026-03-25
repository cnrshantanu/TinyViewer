import Darwin
import Foundation
import Network

// MARK: - Terminal Session

/// Bridges a PTY-backed shell to a single authenticated WebSocket connection.
///
/// Protocol (client ↔ server):
///   • Server → Client  : binary WS frame = raw PTY output bytes
///   • Client → Server  : binary WS frame = raw input bytes  (keyboard)
///                        text   WS frame = JSON `{"type":"resize","cols":N,"rows":N}`
final class TerminalSession {

    let conn: NWConnection
    private let queue: DispatchQueue

    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?

    private(set) var isAlive = false
    var onTerminated: (() -> Void)?

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn  = conn
        self.queue = queue
    }

    // MARK: - Lifecycle

    func start() {
        guard spawnShell() else {
            sendWSBinary(Data("[Terminal] Failed to spawn shell.\r\n".utf8))
            conn.cancel()
            return
        }
        isAlive = true
        startPTYReader()
        readWSFrames(buffer: [])
    }

    func stop() {
        guard isAlive else { return }
        isAlive = false
        readSource?.cancel()
        readSource = nil
        process?.terminate()
        process = nil
        if masterFD >= 0 { Darwin.close(masterFD); masterFD = -1 }
        conn.cancel()
    }

    // MARK: - PTY + Shell

    private func spawnShell() -> Bool {
        // Open a PTY master/slave pair
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0             else { return false }
        guard grantpt(fd)  == 0   else { Darwin.close(fd); return false }
        guard unlockpt(fd) == 0   else { Darwin.close(fd); return false }
        guard let namePtr = ptsname(fd) else { Darwin.close(fd); return false }
        let slaveName = String(cString: namePtr)

        // Initial window size — client sends a resize immediately after connect
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)

        let slaveFD = Darwin.open(slaveName, O_RDWR)
        guard slaveFD >= 0 else { Darwin.close(fd); return false }

        // Build an environment suitable for an interactive shell
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env.removeValue(forKey: "__CF_USER_TEXT_ENCODING")

        let p = Process()
        let shell = FileManager.default.fileExists(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/bash"
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments     = ["--login"]
        p.environment   = env

        // Connect all stdio to the slave side of the PTY
        // closeOnDealloc:false — we close slaveFD manually after run() below
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        p.standardInput  = slaveHandle
        p.standardOutput = slaveHandle
        p.standardError  = slaveHandle

        p.terminationHandler = { [weak self] _ in
            guard let self, self.isAlive else { return }
            self.queue.async {
                self.stop()
                self.onTerminated?()
            }
        }

        do {
            try p.run()
        } catch {
            Darwin.close(fd)
            Darwin.close(slaveFD)
            print("[TerminalSession] Failed to start shell: \(error)")
            return false
        }

        // Close parent's copy of the slave — the child process retains its own
        Darwin.close(slaveFD)

        masterFD = fd
        process  = p
        return true
    }

    // MARK: - Read PTY output → WebSocket

    private func startPTYReader() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.isAlive, self.masterFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(self.masterFD, &buf, buf.count)
            if n > 0 {
                self.sendWSBinary(Data(buf[0..<n]))
            } else if n == 0 || errno != EAGAIN {
                // EOF or fatal error — shell exited
                self.stop()
                self.onTerminated?()
            }
        }
        src.resume()
        readSource = src
    }

    // MARK: - WebSocket frames → PTY input

    func readWSFrames(buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.isAlive else { return }
            guard error == nil, !isComplete else {
                self.stop()
                self.onTerminated?()
                return
            }
            var buf = buffer
            if let data { buf.append(contentsOf: data) }
            self.processWSBuffer(&buf)
            if self.isAlive { self.readWSFrames(buffer: buf) }
        }
    }

    private func processWSBuffer(_ buf: inout [UInt8]) {
        while buf.count >= 2 {
            let b0 = buf[0], b1 = buf[1]
            let opcode  = b0 & 0x0F
            let masked  = (b1 & 0x80) != 0
            var payLen  = Int(b1 & 0x7F)
            var idx     = 2
            if payLen == 126 {
                guard buf.count >= 4 else { return }
                payLen = Int(buf[2]) << 8 | Int(buf[3]); idx = 4
            } else if payLen == 127 {
                guard buf.count >= 10 else { return }
                payLen = (Int(buf[6]) << 24) | (Int(buf[7]) << 16) | (Int(buf[8]) << 8) | Int(buf[9]); idx = 10
            }
            let maskLen  = masked ? 4 : 0
            let frameEnd = idx + maskLen + payLen
            guard buf.count >= frameEnd else { return }

            var payload = Array(buf[(idx + maskLen)..<frameEnd])
            if masked {
                let mk = Array(buf[idx..<(idx + 4)])
                for i in 0..<payload.count { payload[i] ^= mk[i % 4] }
            }
            buf.removeFirst(frameEnd)

            switch opcode {
            case 0x1:   // text frame → JSON control (resize)
                if let text = String(bytes: payload, encoding: .utf8),
                   let jdata = text.data(using: .utf8),
                   let json  = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any],
                   json["type"] as? String == "resize",
                   let cols  = json["cols"] as? Int,
                   let rows  = json["rows"] as? Int,
                   masterFD >= 0 {
                    var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(masterFD, TIOCSWINSZ, &ws)
                    // Signal the foreground process group to re-query terminal size
                    if let pid = process?.processIdentifier, pid > 0 {
                        kill(pid_t(pid), SIGWINCH)
                    }
                }
            case 0x2:   // binary frame → raw keyboard/paste input to shell
                if masterFD >= 0 {
                    let d = Data(payload)
                    _ = d.withUnsafeBytes { ptr in Darwin.write(masterFD, ptr.baseAddress!, d.count) }
                }
            case 0x8:   // WS close
                stop(); onTerminated?(); return
            case 0x9:   // ping → pong
                conn.send(content: Data([0x8A, 0x00]), completion: .contentProcessed { _ in })
            default: break
            }
        }
    }

    // MARK: - WebSocket Framing

    func sendWSBinary(_ data: Data) {
        guard isAlive else { return }
        conn.send(content: wsFrame(data, opcode: 0x82), completion: .contentProcessed { _ in })
    }

    private func wsFrame(_ data: Data, opcode: UInt8) -> Data {
        let len = data.count
        var header = Data([opcode])
        if len < 126 {
            header.append(UInt8(len))
        } else if len <= 65535 {
            header += [126, UInt8(len >> 8), UInt8(len & 0xFF)]
        } else {
            header.append(127)
            for i in stride(from: 7, through: 0, by: -1) { header.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        return header + data
    }
}
