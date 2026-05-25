import Foundation
import Observation

/// Counts card reviews in the current app session and triggers an
/// engagement-driven Walter call once the threshold is hit. State lives
/// in memory only — quitting the app or killing the process resets the
/// counter and the "already called this session" gate, so the user
/// only gets surprised once per day even if they swipe through 60
/// cards across multiple sessions (the daily throttle catches that).
@Observable
@MainActor
final class EngagementTracker {
    static let shared = EngagementTracker()

    /// Cards reviewed since app launch.
    private(set) var cardsReviewedThisSession: Int = 0

    /// True once Walter has engagement-called this session. Prevents
    /// re-triggering if the user keeps swiping.
    private(set) var hasCalledThisSession: Bool = false

    /// Cards needed to earn an engagement call.
    static let callThreshold: Int = 10

    private init() {}

    /// Increments the swipe counter. Fires Walter's call when the
    /// threshold is crossed. Intentionally NOT throttled by
    /// `OnboardingStore.lastWalterCallDate` — engagement calls are
    /// contextually earned by active study, so they should fire even if
    /// the user already had a manual or scheduled call today. The
    /// `hasCalledThisSession` flag still prevents the same launch from
    /// triggering twice.
    func recordCardReview() {
        cardsReviewedThisSession += 1
        guard !hasCalledThisSession,
              cardsReviewedThisSession >= Self.callThreshold
        else { return }

        hasCalledThisSession = true
        IncomingCallCoordinator.shared.requestIncoming()
    }
}
