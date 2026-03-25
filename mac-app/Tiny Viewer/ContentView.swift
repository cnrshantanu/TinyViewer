import Darwin
import IOKit.pwr_mgt
import SwiftUI

// MARK: - Local IP

private func localIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return address }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let iface = ptr {
        let af = iface.pointee.ifa_addr.pointee.sa_family
        if af == UInt8(AF_INET), String(cString: iface.pointee.ifa_name) == "en0" {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.pointee.ifa_addr,
                        socklen_t(iface.pointee.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
        }
        ptr = iface.pointee.ifa_next
    }
    return address
}

// MARK: - Connection mode

enum ConnectionMode: String, CaseIterable {
    case relay  = "Relay (Cloudflare)"
    case direct = "Direct (LAN / H.264)"
}

// MARK: - App State

@Observable
class AppState {

    // Auth
    var currentUser:   (uid: String, email: String)? = nil
    var isSigningIn    = false
    var signInError:   String? = nil

    // Server
    var isRunning        = false
    var clientCount      = 0
    var pin              = ""
    var computerName     = "Mac"
    // Direct (H.264) mode is implemented but not exposed in the release UI.
    // To enable it, add the Mode picker back to DashboardView.
    private(set) var connectionMode = ConnectionMode.relay
    var accessibilityGranted = InputController.isAccessibilityEnabled
    let localIP          = localIPAddress()

    private var permissionPollTask: Task<Void, Never>?
    private var sleepAssertionID: IOPMAssertionID = 0

    // Sub-systems
    let capturer  = ScreenCapturer()
    let server    = MJPEGServer()
    let tunnel    = TunnelManager()
    let firebase  = FirebaseClient()
    // VideoEncoder is compiled but not wired up in the release build.
    // Re-enable by restoring the Mode picker and direct-mode block in startServer().

    // MARK: - Auth

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        Task {
            do {
                let user = try await GoogleAuthManager.shared.signIn()
                await MainActor.run {
                    self.firebase.setUser(user)
                    self.currentUser  = (uid: user.uid, email: user.email)
                    self.isSigningIn  = false
                }
            } catch {
                await MainActor.run {
                    self.signInError  = error.localizedDescription
                    self.isSigningIn  = false
                }
            }
        }
    }

    func signOut() {
        stopServer()
        firebase.signOut()
        currentUser = nil
    }

    /// Called on launch — restores session from Keychain silently.
    func restoreSessionIfPossible() {
        Task {
            if let uid = await firebase.restoreSession(),
               let email = KeychainHelper.load(forKey: "email") {
                await MainActor.run { self.currentUser = (uid: uid, email: email) }
            }
        }
    }

    // MARK: - Server lifecycle

    func startServer() {
        // Clear any stale Firebase presence from a previous session immediately.
        Task { await firebase.setOffline() }

        server.pin            = pin
        server.connectionMode = connectionMode
        server.tokenValidator = { [weak self] token in
            guard let self else { return false }
            return await self.firebase.validateConnectToken(token)
        }
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }

        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Tiny Viewer active session" as CFString,
            &sleepAssertionID
        )

        server.start()

        // Relay — MJPEG over Cloudflare tunnel
        var idleSkip = 0
        let srv = server
        capturer.onFrame = { [weak srv] data in
            guard let srv else { return }
            if srv.isIdle {
                idleSkip += 1
                guard idleSkip % 4 == 0 else { return }
            } else {
                idleSkip = 0
            }
            srv.broadcastFrame(data)
        }
        server.onQualityChange = { [weak self] quality in
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturer.quality = quality
                if self.capturer.isCapturing {
                    self.capturer.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.capturer.start()
                    }
                }
            }
        }
        capturer.start()

        tunnel.onURLDiscovered = { [weak self] url in
            guard let self else { return }
            let name = self.computerName
            Task { await self.firebase.setOnline(url: url, name: name) }
            self.firebase.startHeartbeat { [weak self] in self?.tunnel.status.url }
        }
        tunnel.onTerminated = { [weak self] in
            guard let self else { return }
            Task { await self.firebase.setOffline() }
        }
        tunnel.start()

        isRunning   = true
        clientCount = 0
    }

    func stopServer() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
        firebase.stopHeartbeat()
        if isRunning {
            Task { await firebase.setOffline() }
        }
        tunnel.stop()
        capturer.stop()
        server.stop()
        isRunning   = false
        clientCount = 0
    }

    func recheckAccessibility() {
        accessibilityGranted = InputController.isAccessibilityEnabled
    }

    func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                recheckAccessibility()
                if accessibilityGranted { break }
            }
        }
    }

    func stopPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    // MARK: - Computed helpers

    var publicURL: String? { tunnel.status.url }

    var terminalURL: String? {
        guard isRunning else { return nil }
        return tunnel.status.url.map { $0 + "/terminal" }
    }

    var statusText: String {
        guard isRunning else { return "Idle" }
        return clientCount == 0
            ? "Streaming (no clients)"
            : "\(clientCount) client\(clientCount == 1 ? "" : "s") connected"
    }

    var statusColor: Color {
        guard isRunning else { return .gray }
        return clientCount > 0 ? .green : .orange
    }
}

// MARK: - Root view

struct ContentView: View {
    @State private var state = AppState()

    var body: some View {
        Group {
            if state.currentUser == nil {
                SignInView(state: state)
            } else {
                DashboardView(state: state)
            }
        }
        .frame(width: 380)
        .onAppear {
            state.restoreSessionIfPossible()
        }
    }
}

// MARK: - Sign-in view

struct SignInView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("🖥")
                    .font(.system(size: 52))
                Text("Tiny Viewer")
                    .font(.largeTitle.bold())
                Text("Remote screen access from anywhere")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    state.signIn()
                } label: {
                    HStack(spacing: 10) {
                        if state.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.circle.fill")
                        }
                        Text(state.isSigningIn ? "Opening browser…" : "Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.isSigningIn || !FirebaseConfig.isConfigured)

                if !FirebaseConfig.isConfigured {
                    Label("Fill in FirebaseConfig.swift first", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let err = state.signInError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 280)
        }
        .padding(40)
    }
}

// MARK: - Dashboard view

struct DashboardView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {

            // ── Top bar ────────────────────────────────────────────────────
            HStack {
                Label(state.currentUser?.email ?? "", systemImage: "person.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out") { state.signOut() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // ── Main content ───────────────────────────────────────────────
            VStack(spacing: 18) {

                // Name
                LabeledContent("Name") {
                    TextField("Computer name", text: Binding(
                        get: { state.computerName },
                        set: { state.computerName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.isRunning)
                    .frame(width: 180)
                }

                // PIN
                LabeledContent("PIN") {
                    SecureField("Leave blank to disable", text: Binding(
                        get: { state.pin },
                        set: { state.pin = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.isRunning)
                    .frame(width: 180)
                }

                Divider()

                // Status rows
                VStack(spacing: 8) {
                    StatusRow(
                        label: "Server",
                        value: state.isRunning ? "\(state.localIP):8080" : "Stopped",
                        color: state.isRunning ? .green : .gray
                    )
                    if state.connectionMode == .relay {
                        StatusRow(
                            label: "Tunnel",
                            value: state.tunnel.status.label,
                            color: state.tunnel.status.isRunning ? .green :
                                   (state.isRunning ? .orange : .gray)
                        )
                    }
                    StatusRow(
                        label: "Firebase",
                        value: state.firebase.syncStatus.label,
                        color: state.firebase.syncStatus == .synced ? .green :
                               (state.firebase.syncStatus == .syncing ? .orange : .gray)
                    )
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.capturer.isCapturing ? Color.green : (state.isRunning ? Color.orange : Color.gray))
                            .frame(width: 8, height: 8)
                        Text("Screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .leading)
                        Text(state.capturer.isCapturing ? "Capturing" :
                             (state.capturer.captureError != nil ? "Permission denied" : "Idle"))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if state.isRunning && !state.capturer.isCapturing {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.accessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Control")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .leading)
                        Text(state.accessibilityGranted ? "Accessibility granted" : "Not granted")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if !state.accessibilityGranted {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                // Public URL
                if let url = state.publicURL {
                    URLRow(label: "Stream URL", url: url)
                }

                // Terminal URL
                if let url = state.terminalURL {
                    URLRow(label: "Terminal URL", url: url)
                }

                // Client count
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.statusColor)
                        .frame(width: 8, height: 8)
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Start / Stop
                Button(state.isRunning ? "Stop Server" : "Start Server") {
                    state.isRunning ? state.stopServer() : state.startServer()
                }
                .buttonStyle(.borderedProminent)
                .tint(state.isRunning ? .red : .accentColor)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(20)
        }
        .onAppear  { state.startPermissionPolling() }
        .onDisappear { state.stopPermissionPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.recheckAccessibility()
        }
    }
}

// MARK: - Status row

private struct StatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

// MARK: - URL row

private struct URLRow: View {
    let label: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy URL")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    ContentView()
}
