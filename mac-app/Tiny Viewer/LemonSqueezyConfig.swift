import Foundation

// MARK: - LemonSqueezy Configuration
// Fill these in after creating your product at lemonsqueezy.com

enum LemonSqueezyConfig {
    /// Your LemonSqueezy store URL — set this after you create your product.
    /// Example: "https://yourstore.lemonsqueezy.com/buy/PRODUCT-UUID"
    static let purchaseURL = "https://tinyviewer.lemonsqueezy.com/buy/FILL_IN_PRODUCT_ID"

    /// Whether the config has been filled in (used to show purchase button).
    static var isConfigured: Bool { !purchaseURL.contains("FILL_IN") }
}
