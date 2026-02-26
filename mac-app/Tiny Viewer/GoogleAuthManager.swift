import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - Errors

enum AuthError: Error, LocalizedError {
    case notConfigured
    case listenerFailed
    case noCodeInCallback
    case tokenExchangeFailed(String)
    case firebaseSignInFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:              return "Firebase not configured — fill in FirebaseConfig.swift"
        case .listenerFailed:             return "Could not start local auth server"
        case .noCodeInCallback:           return "Google did not return an auth code"
        case .tokenExchangeFailed(let m): return "Token exchange failed: \(m)"
        case .firebaseSignInFailed(let m):return "Firebase sign-in failed: \(m)"
        case .timeout:                    return "Sign-in timed out (5 minutes)"
        }
    }
}

// MARK: - Result

struct FirebaseUser: Sendable {
    let uid:          String
    let email:        String
    let idToken:      String
    let refreshToken: String
}

// MARK: - Manager

final class GoogleAuthManager {

    static let shared = GoogleAuthManager()
    private init() {}

    // MARK: - Public entry point

    /// Opens the system browser for Google OAuth2, waits for the callback on a
    /// local port, exchanges the code, and signs into Firebase.
    func signIn() async throws -> FirebaseUser {
        guard FirebaseConfig.isConfigured else { throw AuthError.notConfigured }

        let verifier   = makeCodeVerifier()
        let challenge  = makeCodeChallenge(from: verifier)
        let (port, code) = try await listenForCallback(verifier: verifier, challenge: challenge)
        let (gIdToken, gAccessToken) = try await exchangeCode(code, verifier: verifier, port: port)
        return try await signIntoFirebase(idToken: gIdToken, accessToken: gAccessToken)
    }

    // MARK: - PKCE helpers

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Local callback server

    /// Starts a one-shot NWListener, opens Google OAuth in the system browser,
    /// waits for the redirect and returns (port, code).
    private func listenForCallback(verifier: String, challenge: String) async throws -> (UInt16, String) {
        let listener = try NWListener(using: .tcp, on: .any) // OS picks a free port

        // Use a serial queue + reference box so all shared-state mutations are race-free
        let cbQueue = DispatchQueue(label: "com.tinyviewer.oauth-callback")
        final class State: @unchecked Sendable { var port: UInt16 = 0; var resumed = false }
        let s = State()

        func tryResume(_ action: @escaping () -> Void) {
            cbQueue.async {
                guard !s.resumed else { return }
                s.resumed = true
                action()
            }
        }

        return try await withCheckedThrowingContinuation { cont in

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let p = listener.port?.rawValue else {
                        listener.cancel()
                        tryResume { cont.resume(throwing: AuthError.listenerFailed) }
                        return
                    }
                    cbQueue.async { s.port = p }
                    let authURL = self.buildAuthURL(challenge: challenge, port: p)
                    DispatchQueue.main.async { NSWorkspace.shared.open(authURL) }
                case .failed(let e):
                    tryResume { cont.resume(throwing: e) }
                default:
                    break
                }
            }

            // Set newConnectionHandler BEFORE start() to avoid Network framework warnings
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 4, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let code = self.parseCode(from: request)
                    let html: String
                    if let code {
                        html = "<html><head><style>body{font-family:-apple-system;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#111;color:#fff}</style></head><body><h2>✅ Signed in! You can close this tab.</h2></body></html>"
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                            listener.cancel()
                            cbQueue.async { tryResume { cont.resume(returning: (s.port, code)) } }
                        })
                    } else {
                        html = "<html><body><h2>❌ No code received. Please try again.</h2></body></html>"
                        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                            listener.cancel()
                            tryResume { cont.resume(throwing: AuthError.noCodeInCallback) }
                        })
                    }
                }
            }

            listener.start(queue: cbQueue)

            // Timeout after 5 minutes
            cbQueue.asyncAfter(deadline: .now() + 300) {
                guard !s.resumed else { return }
                s.resumed = true
                listener.cancel()
                cont.resume(throwing: AuthError.timeout)
            }
        }
    }

    private func buildAuthURL(challenge: String, port: UInt16) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id",             value: FirebaseConfig.googleClientID),
            .init(name: "redirect_uri",          value: "http://localhost:\(port)"),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: "openid email profile"),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type",           value: "offline"),
            .init(name: "prompt",                value: "consent"),
        ]
        return comps.url!
    }

    private func parseCode(from request: String) -> String? {
        // First line: "GET /?code=XXXX&scope=... HTTP/1.1"
        let first   = request.components(separatedBy: "\r\n").first ?? ""
        let urlPart = first.components(separatedBy: " ").dropFirst().first ?? "/"
        guard let comps = URLComponents(string: "http://localhost" + urlPart) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, verifier: String, port: UInt16) async throws -> (String, String) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code":          code,
            "client_id":     FirebaseConfig.googleClientID,
            "client_secret": FirebaseConfig.googleClientSecret,
            "redirect_uri":  "http://localhost:\(port)",
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken     = json["id_token"]     as? String,
              let accessToken = json["access_token"] as? String
        else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.tokenExchangeFailed(msg)
        }
        return (idToken, accessToken)
    }

    // MARK: - Firebase sign-in with Google credential

    private func signIntoFirebase(idToken: String, accessToken: String) async throws -> FirebaseUser {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(FirebaseConfig.webAPIKey)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody":           "id_token=\(idToken)&access_token=\(accessToken)&providerId=google.com",
            "requestUri":         "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken":  true,
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fbIdToken      = json["idToken"]      as? String,
              let fbRefreshToken = json["refreshToken"] as? String,
              let uid            = json["localId"]      as? String,
              let email          = json["email"]        as? String
        else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.firebaseSignInFailed(msg)
        }
        return FirebaseUser(uid: uid, email: email, idToken: fbIdToken, refreshToken: fbRefreshToken)
    }
}
