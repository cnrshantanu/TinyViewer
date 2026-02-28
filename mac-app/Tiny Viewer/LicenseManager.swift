import Foundation

// MARK: - License Manager

/// Manages the 1-year free trial and lifetime license activation.
///
/// Trial start date is stored in UserDefaults on first launch.
/// License key + email are stored in UserDefaults after activation.
/// Activation makes one network call to LemonSqueezy, then runs fully offline.
@Observable
final class LicenseManager {

    static let shared = LicenseManager()
    private init() {}

    // MARK: - State

    enum LicenseState: Equatable {
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed(email: String)
    }

    private(set) var state: LicenseState = .trial(daysRemaining: 365)
    private(set) var isActivating = false
    private(set) var activationError: String?

    /// True while the user can run the app (trial active or licensed).
    var isAllowed: Bool {
        switch state {
        case .trial, .licensed: return true
        case .trialExpired:     return false
        }
    }

    /// Days left in trial, or nil if licensed / expired.
    var daysRemainingInTrial: Int? {
        if case .trial(let d) = state { return d }
        return nil
    }

    // MARK: - Initialise (call once on launch)

    func initialize() {
        // Restore license first (cheapest check)
        if let key   = KeychainHelper.load(forKey: "licenseKey"),
           let email = KeychainHelper.load(forKey: "licenseEmail"),
           !key.isEmpty, !email.isEmpty {
            state = .licensed(email: email)
            return
        }

        // Fall back to trial period
        let firstLaunch = ensureFirstLaunchDate()
        let days = Calendar.current
            .dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        let remaining = max(0, 365 - days)
        state = remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }

    // MARK: - Activation

    func activateLicense(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            isActivating    = true
            activationError = nil
        }

        do {
            let email = try await LemonSqueezyClient.validate(licenseKey: trimmed)
            KeychainHelper.save(trimmed, forKey: "licenseKey")
            KeychainHelper.save(email,   forKey: "licenseEmail")
            await MainActor.run {
                state        = .licensed(email: email)
                isActivating = false
            }
        } catch {
            await MainActor.run {
                activationError = error.localizedDescription
                isActivating    = false
            }
        }
    }

    // MARK: - Helpers

    private func ensureFirstLaunchDate() -> Date {
        if let stored = KeychainHelper.load(forKey: "firstLaunchDate"),
           let ts = Double(stored) {
            return Date(timeIntervalSince1970: ts)
        }
        let now = Date()
        KeychainHelper.save(String(now.timeIntervalSince1970), forKey: "firstLaunchDate")
        return now
    }
}

// MARK: - LemonSqueezy Client

enum LemonSqueezyClient {

    enum ValidationError: LocalizedError {
        case invalidKey
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey:    return "Invalid license key. Please check and try again."
            case .network(let m): return "Network error: \(m)"
            }
        }
    }

    /// Calls the LemonSqueezy license validation API.
    /// Returns the customer email on success.
    static func validate(licenseKey: String) async throws -> String {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate") else {
            throw ValidationError.invalidKey
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "license_key":   licenseKey,
            "instance_name": Host.current().localizedName ?? "Mac"
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse

        guard http.statusCode == 200 else {
            if http.statusCode == 400 {
                throw ValidationError.invalidKey
            }
            throw ValidationError.network("HTTP \(http.statusCode)")
        }

        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valid = json["valid"] as? Bool, valid,
              let meta  = json["meta"] as? [String: Any],
              let email = meta["customer_email"] as? String else {
            throw ValidationError.invalidKey
        }

        return email
    }
}
