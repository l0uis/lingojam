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

    private init() {}

    func requestIncoming() {
        // Kill any card-stack pronunciation (or other in-flight TTS) so
        // the example sentence behind the call screen doesn't bleed
        // through the ringer.
        SpeechService.shared.stop()
        isPresentingIncoming = true
    }

    func requestOutgoing() {
        SpeechService.shared.stop()
        isPresentingOutgoing = true
    }
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
        let kind = response.notification.request.content.userInfo["kind"] as? String
        if kind == NotificationService.walrusCallCategory {
            Task { @MainActor in
                IncomingCallCoordinator.shared.requestIncoming()
            }
        }
        completionHandler()
    }
}
