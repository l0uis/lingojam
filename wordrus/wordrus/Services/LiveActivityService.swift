import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Drives the rotating-word Live Activity on the Lock Screen / Dynamic Island.
///
/// Live Activities have no self-refreshing timeline (unlike the home-screen
/// widget), so the content only advances when we call `update`. We drive that
/// on-device from two triggers — the app coming to the foreground and a
/// throttled `BGAppRefreshTask` — and compute *which* word to show purely from
/// the clock via `DailyWordRotation`, so every update lands on the correct word
/// for "now" no matter how sparsely iOS grants us background time.
///
/// Starting an activity requires the app to be in the foreground (there is no
/// push-to-start infrastructure), so `start()` is only ever called from the
/// Settings toggle and the launch bootstrap.
@MainActor
enum LiveActivityService {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the app Info.plist.
    static let backgroundTaskID = "com.louiscurrie.wordrus.liveactivity.refresh"

    /// Whether the user has switched the feature on (Settings toggle).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: OnboardingDefaultsKey.liveActivityEnabled)
    }

    /// Whether the system currently permits Live Activities for this app.
    static var isSupported: Bool {
        #if canImport(ActivityKit)
        ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        false
        #endif
    }

    // MARK: - Lifecycle

    /// Ensure an activity is running and pointed at the current word. Safe to
    /// call repeatedly (e.g. on every launch); no-ops unless enabled, supported
    /// and today's set exists.
    static func start(now: Date = .now) {
        #if canImport(ActivityKit)
        guard isEnabled, isSupported,
              let set = DailyWordSet.load(), !set.words.isEmpty else { return }

        if currentActivity != nil {
            refresh(now: now)
        } else {
            do {
                _ = try Activity.request(
                    attributes: WordActivityAttributes(),
                    content: content(for: set, now: now),
                    pushType: nil
                )
            } catch {
                // Requesting can fail if the user disabled Live Activities in
                // Settings or the per-app activity limit is hit — nothing we can
                // recover here; the toggle simply won't show anything.
            }
        }
        scheduleNextRefresh(now: now)
        #endif
    }

    /// Advance a *running* activity to the word for `now`. Never starts one —
    /// safe to call from the background and from `DailyWordService.publishSet`.
    static func refresh(now: Date = .now) {
        #if canImport(ActivityKit)
        guard currentActivity != nil,
              let set = DailyWordSet.load(), !set.words.isEmpty else { return }
        Task { await applyCurrentWord(set: set, now: now) }
        #endif
    }

    /// Tear down any running activity (Settings toggle off).
    static func end() {
        #if canImport(ActivityKit)
        Task {
            for activity in Activity<WordActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        cancelScheduledRefresh()
        #endif
    }

    // MARK: - Content

    #if canImport(ActivityKit)
    private static var currentActivity: Activity<WordActivityAttributes>? {
        Activity<WordActivityAttributes>.activities.first
    }

    private static func content(
        for set: DailyWordSet,
        now: Date
    ) -> ActivityContent<WordActivityAttributes.ContentState> {
        let count = set.words.count
        let idx = DailyWordRotation.index(at: now, count: count, since: set.computedAt)
        let state = WordActivityAttributes.ContentState(
            snapshot: set.words[idx],
            index: idx,
            total: count
        )
        let staleDate = DailyWordRotation.nextBoundary(at: now, count: count, since: set.computedAt)
        return ActivityContent(state: state, staleDate: staleDate)
    }

    private static func applyCurrentWord(set: DailyWordSet, now: Date) async {
        guard let activity = currentActivity else { return }
        let next = content(for: set, now: now)
        // Skip a redundant update when the shown word hasn't changed.
        if activity.content.state == next.state { return }
        await activity.update(next)
    }
    #endif

    // MARK: - Background refresh

    /// Register the refresh task handler. Must run once at launch, before the
    /// app finishes launching (call from `App.init`).
    static func registerBackgroundTask() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The launch handler runs off the main actor; hop back on to touch
            // ActivityKit and reschedule.
            Task { @MainActor in
                scheduleNextRefresh()
                #if canImport(ActivityKit)
                if let set = DailyWordSet.load(), !set.words.isEmpty {
                    await applyCurrentWord(set: set, now: .now)
                }
                #endif
                refreshTask.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    /// Ask iOS to wake us near the next rotation boundary. Best-effort — the
    /// system decides when (or whether) to actually run it.
    static func scheduleNextRefresh(now: Date = .now) {
        #if canImport(BackgroundTasks)
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        if let set = DailyWordSet.load(), !set.words.isEmpty {
            request.earliestBeginDate = DailyWordRotation.nextBoundary(
                at: now, count: set.words.count, since: set.computedAt
            )
        } else {
            request.earliestBeginDate = now.addingTimeInterval(3600)
        }
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    static func cancelScheduledRefresh() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskID)
        #endif
    }
}
