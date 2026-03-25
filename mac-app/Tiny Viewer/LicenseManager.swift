import Foundation

// MARK: - License Manager
//
// App is currently free — state is always .licensed.
// Monetisation stub is preserved for a future paid tier:
//   - Re-enable checkLicense() to gate on Firestore licenses/{email}
//   - Wire up LemonSqueezy webhook → Cloud Function → Firestore

@Observable
final class LicenseManager {

    static let shared = LicenseManager()
    private init() {}

    // MARK: - State

    enum LicenseState: Equatable {
        case unknown
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed
    }

    private(set) var state: LicenseState = .licensed

    var isAllowed: Bool { true }

    var daysRemainingInTrial: Int? { nil }

    // MARK: - Lifecycle

    /// Call once on launch. App is free so this is a no-op.
    func initialize() {
        state = .licensed
    }

    /// Placeholder for future paid-tier check against Firestore.
    func checkLicense(email: String, using firebase: FirebaseClient) async {
        // Free tier — always licensed.
    }

    func clearLicense() {
        state = .licensed
    }
}
