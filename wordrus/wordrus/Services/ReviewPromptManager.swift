import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Decides when to ask for an App Store rating.
///
/// iOS shows the system prompt at most three times a year per person, so
/// each request is spent on a moment the learner has just enjoyed — never
/// before they've used the app (asking straight after onboarding, as 1.1.7
/// did, burned a request on people who hadn't seen a card yet).
///
/// Both triggers live on the end-of-call result sheet: finishing the day's
/// set rings Dr Tusk, so the call's result is where a session naturally ends.
/// - `goodCall`: the call passed (≥ 3 target words used).
/// - `returningUser`: any call on the learner's 2nd+ day with 20+ cards
///   reviewed, so people who struggle on calls still get asked eventually.
///
/// At most one request per app version, and 30 days between requests.
@MainActor
enum ReviewPromptManager {

    static let returningMinActiveDays = 2
    static let returningMinCardsReviewed = 20
    static let minDaysBetweenRequests = 30

    private static let lastRequestedVersionKey = "reviewPrompt.lastRequestedVersion"
    private static let lastRequestedAtKey = "reviewPrompt.lastRequestedAt"
    private static let activeDaysKey = "reviewPrompt.activeDays"
    private static let lastActiveDayKey = "reviewPrompt.lastActiveDay"
    private static let cardsReviewedKey = "reviewPrompt.cardsReviewed"

    private static var defaults: UserDefaults { .standard }

    // MARK: Signals

    /// Call when the app becomes active. Counts distinct days the app was used.
    static func noteAppActive(now: Date = .now) {
        let today = DailySetConfig.dayKey(now)
        guard defaults.string(forKey: lastActiveDayKey) != today else { return }
        defaults.set(today, forKey: lastActiveDayKey)
        defaults.set(defaults.integer(forKey: activeDaysKey) + 1, forKey: activeDaysKey)
    }

    /// Call on every card rating, from any tab.
    static func noteCardReviewed() {
        defaults.set(defaults.integer(forKey: cardsReviewedKey) + 1, forKey: cardsReviewedKey)
    }

    /// Call once the call result sheet has gone away.
    static func callResultDismissed(passed: Bool, now: Date = .now) {
        let trigger: Analytics.ReviewTrigger
        if passed {
            trigger = .goodCall
        } else if defaults.integer(forKey: activeDaysKey) >= returningMinActiveDays,
                  defaults.integer(forKey: cardsReviewedKey) >= returningMinCardsReviewed {
            trigger = .returningUser
        } else {
            return
        }
        guard canRequest(now: now) else { return }

        Task { @MainActor in
            // Let the sheet finish sliding away so the prompt lands on the tab,
            // not on a half-dismissed sheet.
            try? await Task.sleep(for: .milliseconds(700))
            guard let scene = activeScene, canRequest(now: now) else { return }
            defaults.set(currentVersion, forKey: lastRequestedVersionKey)
            defaults.set(now, forKey: lastRequestedAtKey)
            Analytics.reviewPromptRequested(trigger)
            AppStore.requestReview(in: scene)
        }
    }

    // MARK: Throttle

    private static func canRequest(now: Date) -> Bool {
        if defaults.string(forKey: lastRequestedVersionKey) == currentVersion { return false }
        if let last = defaults.object(forKey: lastRequestedAtKey) as? Date,
           now.timeIntervalSince(last) < TimeInterval(minDaysBetweenRequests) * 86_400 {
            return false
        }
        return true
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    #if canImport(UIKit)
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif
}
