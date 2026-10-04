import Foundation
#if canImport(PostHog)
import PostHog
#endif
import UIKit

// MARK: - Constants

enum AnalyticsConstants {
    /// PostHog project API key: the public, write-only `phc_…` token from
    /// Project Settings → Project API key (safe to ship, like the RevenueCat
    /// key). Leave empty to disable analytics entirely — `Analytics.configure()`
    /// is a no-op without a token.
    static let projectToken = "phc_wjG5FYm4cFCQSgtjapuZNBNvybahL5WvvyVVUx5ACzt3"

    /// EU ingestion endpoint (the project lives on PostHog Cloud EU).
    static let host = "https://eu.i.posthog.com"
}

// MARK: - Analytics

/// Thin, privacy-first wrapper around the PostHog SDK. Same rules as WeekOS:
/// - Anonymous. `identify()` is never called; PostHog only sees a random
///   per-install id. No email, name, Apple ID or IDFA.
/// - No user content in properties, ever (App Review 5.1.3).
/// - Autocapture, screen views, session replay, surveys and push tracking are
///   off. Only the explicit `capture` calls plus PostHog's lifecycle events.
/// - The user can switch it off in Settings (`isEnabled`).
/// - DEBUG builds never send unless the `analyticsDebugSend` UserDefault is true.
enum Analytics {

    // MARK: Events (snake_case raw values are the dashboard's contract — never rename)

    enum Event: String {
        case onboardingCompleted = "onboarding_completed"
        case cardReviewed = "card_reviewed"
        case callStarted = "call_started"
        case callEnded = "call_ended"
        case paywallShown = "paywall_shown"
        case paywallDismissed = "paywall_dismissed"
        case purchaseCompleted = "purchase_completed"
        case purchaseRestored = "purchase_restored"
        case reviewPromptRequested = "review_prompt_requested"
        case analyticsDisabled = "analytics_disabled"
    }

    /// What the user tapped to reach the paywall. `unknown` means a presenter
    /// forgot to pass a source.
    enum PaywallSource: String {
        case onboarding
        case settings
        case call
        case jamTopic = "jam_topic"
        case myWords = "my_words"
        case deckPicker = "deck_picker"
        case story
        case unknown
    }

    enum PaywallOutcome: String {
        case purchased
        case restored
        case closed
    }

    enum ReviewTrigger: String {
        case afterOnboarding = "after_onboarding"
    }

    // MARK: Opt-out

    private static let enabledKey = "analyticsEnabled"
    private static let debugSendKey = "analyticsDebugSend"

    /// User-facing switch. Defaults to on; flipping it off opts the SDK out
    /// immediately and persists across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            let wasEnabled = isEnabled
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            #if canImport(PostHog)
            guard isConfigured else { return }
            if newValue {
                PostHogSDK.shared.optIn()
            } else if wasEnabled {
                PostHogSDK.shared.capture(Event.analyticsDisabled.rawValue)
                PostHogSDK.shared.flush()
                PostHogSDK.shared.optOut()
            }
            #endif
        }
    }

    private static var isConfigured = false

    // MARK: Setup

    /// Call once, as early as possible in launch, so PostHog's
    /// "Application Opened" fires. No network until the first flush.
    static func configure() {
        guard !isConfigured else { return }
        guard !AnalyticsConstants.projectToken.isEmpty else { return }

        #if DEBUG
        guard UserDefaults.standard.bool(forKey: debugSendKey) else { return }
        #endif

        #if canImport(PostHog)
        let config = PostHogConfig(projectToken: AnalyticsConstants.projectToken,
                                   host: AnalyticsConstants.host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.personProfiles = .identifiedOnly   // never identified → anonymous
        config.optOut = !isEnabled
        config.sessionReplay = false
        config.surveys = false
        config.captureElementInteractions = false
        config.rageClickConfig.enabled = false

        // Local hour / weekday on every event (PostHog stores UTC), and the
        // static properties merged in for "Application Installed", which the
        // SDK captures inside `setup()` before `register` can run.
        config.setBeforeSend { event in
            let now = Date()
            let calendar = Calendar.current
            let weekdayIndex = (calendar.component(.weekday, from: now) + 5) % 7 // Mon = 0
            event.properties["local_hour"] = calendar.component(.hour, from: now)
            event.properties["weekday"] = weekdayNames[weekdayIndex]
            event.properties["is_weekend"] = weekdayIndex >= 5
            for (key, value) in superProperties where event.properties[key] == nil {
                event.properties[key] = value
            }
            return event
        }

        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(superProperties)
        isConfigured = true
        #endif
    }

    private static let weekdayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// Attached to every event. Static for the life of the process.
    private static let superProperties: [String: Any] = {
        var props: [String: Any] = [:]
        props["platform"] = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let info = Bundle.main.infoDictionary
        props["app_version"] = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        props["app_build"] = info?["CFBundleVersion"] as? String ?? "unknown"
        props["language"] = Locale.current.language.languageCode?.identifier ?? "unknown"
        props["region"] = Locale.current.region?.identifier ?? "unknown"
        // Skip PostHog's server-side GeoIP step (city / postal code / lat-long
        // from the IP). `region` is the device locale, not a location.
        props["$geoip_disable"] = true
        return props
    }()

    /// The anonymous PostHog id for this install, or nil when analytics is off.
    /// Handed to RevenueCat so its PostHog integration attaches purchase and
    /// renewal events to the same anonymous person.
    static var distinctId: String? {
        #if canImport(PostHog)
        guard isConfigured, isEnabled else { return nil }
        return PostHogSDK.shared.getDistinctId()
        #else
        return nil
        #endif
    }

    /// Keep the `is_pro` super property current so every event splits by
    /// free vs. paying.
    static func setIsPro(_ isPro: Bool) {
        #if canImport(PostHog)
        guard isConfigured else { return }
        PostHogSDK.shared.register(["is_pro": isPro])
        #endif
    }

    // MARK: Capture

    static func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        #if canImport(PostHog)
        guard isConfigured else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
        #endif
    }

    // MARK: Paywall

    /// Call once per paywall presentation (the view guards against a second
    /// `onAppear` for the same sheet).
    static func paywallShown(_ source: PaywallSource) {
        capture(.paywallShown, ["source": source.rawValue])
    }

    static func paywallDismissed(source: PaywallSource, outcome: PaywallOutcome, shownAt: Date) {
        capture(.paywallDismissed, [
            "source": source.rawValue,
            "outcome": outcome.rawValue,
            "time_open_bucket": timeOpenBucket(Date().timeIntervalSince(shownAt))
        ])
    }

    /// Coarse buckets: "bounced instantly" vs "read it" is the whole question.
    static func timeOpenBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3: return "<3s"
        case ..<10: return "3-10s"
        case ..<30: return "10-30s"
        case ..<120: return "30-120s"
        default: return "120s+"
        }
    }

    /// Coarse duration buckets keep the dashboard readable and never send exact times.
    static func durationBucket(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        switch minutes {
        case ..<1: return "<1m"
        case ..<3: return "1-3m"
        case ..<10: return "3-10m"
        case ..<30: return "10-30m"
        default: return "30m+"
        }
    }

    // MARK: Review prompt

    /// Fired when the app actually asks StoreKit for a review. The system
    /// decides whether a dialog appears and never reports back, so this counts
    /// requests, not impressions or ratings.
    static func reviewPromptRequested(_ trigger: ReviewTrigger) {
        capture(.reviewPromptRequested, ["trigger": trigger.rawValue])
    }

}
