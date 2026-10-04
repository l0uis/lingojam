import Foundation
import Observation
import UserNotifications

/// App-wide signal that an incoming walrus call should be presented.
/// `RootView` observes this and shows `CallIncomingView` when raised.
/// Set from two sources:
///   1. Tapping a scheduled walrus call notification (via `NotificationDelegate`)
///   2. User initiating a call from the Phone tab (outgoing) — uses
///      `requestOutgoing()` to skip the ringer.
@Observable
@MainActor
final class IncomingCallCoordinator {
    static let shared = IncomingCallCoordinator()

    /// True while the incoming-call screen should be presented over the
    /// current UI.
    var isPresentingIncoming: Bool = false

    /// True while an outgoing call should jump straight into the chat
    /// view (no ringer).
    var isPresentingOutgoing: Bool = false

    /// What to talk about on the next outgoing call, when it isn't the usual
    /// recent-words call — e.g. retelling today's story. Consumed by
    /// `RootView` when it presents the call.
    var pendingSeed: CallSeed?

    private init() {}

    func requestIncoming() {
        Analytics.capture(.callStarted, ["direction": "incoming"])
        // Kill any card-stack pronunciation (or other in-flight TTS) so
        // the example sentence behind the call screen doesn't bleed
        // through the ringer.
        SpeechService.shared.stop()
        isPresentingIncoming = true
    }

    func requestOutgoing(seed: CallSeed? = nil) {
        Analytics.capture(.callStarted, ["direction": "outgoing"])
        SpeechService.shared.stop()
        pendingSeed = seed
        isPresentingOutgoing = true
    }
}

/// A call built around something specific instead of recent review words.
struct CallSeed: Equatable {
    /// Words Dr Tusk tries to get the learner to use.
    let wordIDs: [String]
    /// Background the brain gets with its instructions (in English).
    let storyContext: String
}

/// Foreground/launched notification handler. Routes walrus call taps to
/// the `IncomingCallCoordinator`.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    // Show banner + sound for walrus call notifications when the app is
    // already foreground — otherwise the ring is silent and confusing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo["kind"] as? String
        if kind == NotificationService.walrusCallCategory {
            Task { @MainActor in
                IncomingCallCoordinator.shared.requestIncoming()
            }
        } else if kind == "DAILY_STORY",
                  let raw = userInfo["storyID"] as? String, let storyID = UUID(uuidString: raw) {
            // Matches `StoryScheduler.notificationKind`.
            Task { @MainActor in
                DeepLinkCoordinator.shared.request(storyID: storyID)
            }
        } else if let wordID = userInfo["wordID"] as? String {
            // A tapped daily-word reminder: surface that exact word over
            // whatever the user lands on. Routed the same as a widget/Live
            // Activity tap so all three entry points behave identically.
            Task { @MainActor in
                DeepLinkCoordinator.shared.request(wordID: wordID)
            }
        }
        completionHandler()
    }
}
