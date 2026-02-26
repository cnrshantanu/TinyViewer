import Foundation

// MARK: - Errors

enum FirebaseError: Error, LocalizedError {
    case notAuthenticated
    case serverError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:            return "Not signed in"
        case .serverError(let c, let m):  return "Firebase \(c): \(m)"
        case .decodingError:              return "Unexpected Firebase response"
        }
    }
}

// MARK: - Client

@Observable
class FirebaseClient {

    enum SyncStatus: Equatable {
        case idle, syncing, synced
        case failed(String)

        var label: String {
            switch self {
            case .idle:           return "Idle"
            case .syncing:        return "Syncing…"
            case .synced:         return "Synced"
            case .failed(let m):  return "Error: \(m)"
            }
        }
    }

    private(set) var syncStatus: SyncStatus = .idle

    // Tokens — written only on main actor; read inside async tasks via capture
    private var idToken:      String?
    private var refreshToken: String?
    private var tokenExpiry:  Date?
    private var uid:          String?
    private var currentName:  String = "Mac"

    private var heartbeatTimer: Timer?
    private let session = URLSession.shared

    // MARK: - Session management

    func setUser(_ user: FirebaseUser) {
        idToken      = user.idToken
        refreshToken = user.refreshToken
        tokenExpiry  = Date().addingTimeInterval(3600)
        uid          = user.uid
        KeychainHelper.save(user.refreshToken, forKey: "refreshToken")
        KeychainHelper.save(user.uid,          forKey: "uid")
        KeychainHelper.save(user.email,        forKey: "email")
    }

    /// Attempts a silent sign-in using a stored refresh token.
    /// Returns the uid on success, nil if no stored token or refresh fails.
    func restoreSession() async -> String? {
        guard let refresh = KeychainHelper.load(forKey: "refreshToken"),
              let storedUID = KeychainHelper.load(forKey: "uid") else { return nil }
        refreshToken = refresh
        uid          = storedUID
        do {
            try await refreshAccessToken()
            return storedUID
        } catch {
            print("[Firebase] Session restore failed: \(error)")
            KeychainHelper.clear()
            return nil
        }
    }

    func signOut() {
        idToken = nil; refreshToken = nil; tokenExpiry = nil; uid = nil
        stopHeartbeat()
        syncStatus = .idle
        KeychainHelper.clear()
    }

    // MARK: - Token refresh

    private func refreshAccessToken() async throws {
        guard let refresh = refreshToken else { throw FirebaseError.notAuthenticated }

        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(FirebaseConfig.webAPIKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type":    "refresh_token",
            "refresh_token": refresh,
        ])

        let (data, response) = try await session.data(for: req)
        try checkHTTP(data: data, response: response)

        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token     = json["id_token"]      as? String,
              let newRefresh = json["refresh_token"] as? String,
              let expiresIn  = json["expires_in"]   as? String,
              let seconds    = Double(expiresIn)
        else { throw FirebaseError.decodingError }

        idToken      = token
        refreshToken = newRefresh
        tokenExpiry  = Date().addingTimeInterval(seconds)
        KeychainHelper.save(newRefresh, forKey: "refreshToken")
    }

    private func validToken() async throws -> String {
        if let t = idToken, let exp = tokenExpiry, Date() < exp.addingTimeInterval(-300) {
            return t
        }
        try await refreshAccessToken()
        guard let t = idToken else { throw FirebaseError.notAuthenticated }
        return t
    }

    // MARK: - Firestore sync

    func setOnline(url: String, name: String) async {
        currentName = name
        await patchTunnel(["status": "online", "url": url, "name": name])
    }

    func setOffline() async {
        await patchTunnel(["status": "offline"])
    }

    private func patchTunnel(_ fields: [String: String]) async {
        await MainActor.run { syncStatus = .syncing }
        do {
            let token = try await validToken()
            guard let uid else { throw FirebaseError.notAuthenticated }

            var firestoreFields: [String: Any] = [:]
            for (k, v) in fields { firestoreFields[k] = ["stringValue": v] }
            firestoreFields["lastSeen"] = ["timestampValue": ISO8601DateFormatter().string(from: Date())]

            let docURL = URL(string: "https://firestore.googleapis.com/v1/projects/\(FirebaseConfig.projectID)/databases/(default)/documents/tunnels/\(uid)")!
            var req = URLRequest(url: docURL)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": firestoreFields])

            let (data, response) = try await session.data(for: req)
            try checkHTTP(data: data, response: response)
            await MainActor.run { syncStatus = .synced }
        } catch {
            await MainActor.run { syncStatus = .failed(error.localizedDescription) }
            print("[Firebase] Sync error: \(error)")
        }
    }

    // MARK: - Connect token validation

    /// Verifies a Firebase ID token issued by the web app.
    /// Uses identitytoolkit to confirm the token is valid and belongs to this Mac's owner.
    /// No Firestore write or read needed — validates in one fast network call.
    func validateConnectToken(_ idToken: String) async -> Bool {
        guard !idToken.isEmpty, let ownerUID = uid else { return false }
        do {
            var req = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=\(FirebaseConfig.webAPIKey)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["idToken": idToken])

            let (data, response) = try await session.data(for: req)
            try checkHTTP(data: data, response: response)

            guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let users    = json["users"] as? [[String: Any]],
                  let first    = users.first,
                  let tokenUID = first["localId"] as? String,
                  tokenUID == ownerUID
            else { return false }

            return true
        } catch {
            print("[Firebase] Token validation error: \(error)")
            return false
        }
    }

    // MARK: - Heartbeat (keeps lastSeen fresh; re-registers if URL changed)

    func startHeartbeat(urlProvider: @escaping @Sendable () -> String?) {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, let url = urlProvider() else { return }
            let name = self.currentName
            Task { await self.setOnline(url: url, name: name) }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Helpers

    private func checkHTTP(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw FirebaseError.serverError(http.statusCode, msg)
        }
    }
}
