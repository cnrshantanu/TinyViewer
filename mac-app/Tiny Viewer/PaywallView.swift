import SwiftUI

// MARK: - Paywall (shown when trial expires)

struct PaywallView: View {
    @State private var licenseKey = ""
    private let license = LicenseManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("🖥")
                    .font(.system(size: 48))
                Text("Tiny Viewer")
                    .font(.largeTitle.bold())
                Text("Your 1-year free trial has ended.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 20)

            Divider()

            // Value props
            VStack(alignment: .leading, spacing: 10) {
                FeatureRow("Lifetime access — no subscription")
                FeatureRow("All future updates included")
                FeatureRow("Self-hosted — your data never leaves your Mac")
                FeatureRow("Works anywhere via Cloudflare tunnel")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()

            // Purchase button
            VStack(spacing: 16) {
                Button {
                    NSWorkspace.shared.open(URL(string: LemonSqueezyConfig.purchaseURL)!)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cart.fill")
                        Text("Get Tiny Viewer — $15")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!LemonSqueezyConfig.isConfigured)

                if !LemonSqueezyConfig.isConfigured {
                    Text("Fill in LemonSqueezyConfig.swift to enable purchases")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("One-time payment · PPP pricing applied at checkout")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            // License key activation
            VStack(spacing: 8) {
                Text("Already purchased? Enter your license key:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(license.isActivating)

                    Button {
                        Task { await license.activateLicense(licenseKey) }
                    } label: {
                        if license.isActivating {
                            ProgressView().controlSize(.small).frame(width: 44)
                        } else {
                            Text("Activate")
                        }
                    }
                    .disabled(licenseKey.trimmingCharacters(in: .whitespaces).isEmpty
                              || license.isActivating)
                }

                if let err = license.activationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
    }
}

// MARK: - Trial Banner (shown in dashboard when < 30 days remaining)

struct TrialBanner: View {
    let daysRemaining: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.orange)
            Text("\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left in free trial")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Buy $15") {
                NSWorkspace.shared.open(URL(string: LemonSqueezyConfig.purchaseURL)!)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

// MARK: - Helpers

private struct FeatureRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.primary)
            .labelStyle(GreenCheckLabelStyle())
    }
}

private struct GreenCheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
    }
}
