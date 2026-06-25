import Foundation

/// Canonical legal URLs surfaced in the subscription purchase flow. App Review
/// Guideline 3.1.2(c) requires functional Terms of Use (EULA) and Privacy
/// Policy links inside the app for auto-renewable subscriptions. The same two
/// links must also appear in App Store Connect (Privacy Policy field + the
/// App Description / EULA field).
enum LegalLinks {
    /// Apple's standard Terms of Use (EULA). Using the standard EULA means the
    /// matching App Store metadata link goes in the App Description.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static let privacyPolicy = URL(string: "https://www.louiscurrie.com/privacy-policy-wordrus")!
}
