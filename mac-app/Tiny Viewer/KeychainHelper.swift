import Foundation

// Stores session tokens in UserDefaults — no keychain prompts.
// Acceptable for a personal unsandboxed app.
enum KeychainHelper {

    private static let prefix = "com.tinyviewer."

    static func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func load(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func delete(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    static func clear() {
        for key in ["refreshToken", "uid", "email"] { delete(forKey: key) }
    }
}
