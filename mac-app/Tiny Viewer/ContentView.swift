import Darwin
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

// MARK: - App State

@Observable
class AppState {

    // Auth
    var currentUser:   (uid: String, email: String)? = nil
    var isSigningIn    = false
    var signInError:   String? = nil

    // Server
    var isRunning      = false
    var clientCount    = 0
    var pin            = ""
    var computerName   = "Mac"
    var accessibilityGranted = InputController.isAccessibilityEnabled
    let localIP        = localIPAddress()

    private var permissionPollTask: Task<Void, Never>?

    // Sub-systems
    let capturer  = ScreenCapturer()
    let server    = MJPEGServer()
    let tunnel    = TunnelManager()
    let firebase  = FirebaseClient()

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
        server.pin = pin
        server.tokenValidator = { [weak self] token in
            guard let self else { return false }
            return await self.firebase.validateConnectToken(token)
        }
        let srv = server
        capturer.onFrame = { [weak srv] data in srv?.broadcastFrame(data) }
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }
        capturer.start()
        server.start()

        tunnel.onURLDiscovered = { [weak self] url in
            guard let self else { return }
            let name = self.computerName
            Task { await self.firebase.setOnline(url: url, name: name) }
            self.firebase.startHeartbeat { [weak self] in self?.tunnel.status.url }
        }
        tunnel.start()

        isRunning   = true
        clientCount = 0
    }

    func stopServer() {
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
        .frame(minWidth: 380, minHeight: 300)
        .onAppear { state.restoreSessionIfPossible() }
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
            ScrollView {
                VStack(spacing: 18) {

                    // Quality
                    LabeledContent("Quality") {
                        Picker("", selection: Binding(
                            get: { state.capturer.quality },
                            set: { state.capturer.quality = $0 }
                        )) {
                            ForEach(StreamQuality.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(state.isRunning)
                        .frame(width: 180)
                    }

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
                        StatusRow(
                            label: "Tunnel",
                            value: state.tunnel.status.label,
                            color: state.tunnel.status.isRunning ? .green :
                                   (state.isRunning ? .orange : .gray)
                        )
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Public URL")
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

#Preview {
    ContentView()
}
