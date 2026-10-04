import Foundation
import SwiftData
import UserNotifications
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Gets today's story written before the learner asks for it, and tells them
/// when a new one is waiting.
///
/// - Background: a daily `BGAppRefreshTask` writes the story overnight /
///   early morning and schedules a "new story" notification.
/// - Foreground: coming back to the app writes today's story if it's still
///   missing (no notification — the Phone tab shows it as unread).
/// - Opening the story generates it on demand as the last resort
///   (`TodayStoryScreen`).
@MainActor
enum StoryScheduler {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the app Info.plist.
    static let backgroundTaskID = "com.louiscurrie.wordrus.story.refresh"
    /// `userInfo["kind"]` of the new-story notification.
    static let notificationKind = "DAILY_STORY"
    static let notificationIdentifierPrefix = "wordrus.story."
    /// The story notification never lands this close to a word reminder.
    static let reminderGap: TimeInterval = 45 * 60

    /// Stories are Pro-only and need a finished onboarding (language,
    /// level, seeded words). Free users are never written for in the
    /// background, so they never cost a Claude call.
    private static var isReady: Bool {
        Entitlements.shared.isPro && OnboardingStore.hasCompleted && OnboardingStore.targetLanguage != nil
    }

    // MARK: - Foreground

    /// Writes today's story ahead of time if it's missing. Quiet: failures
    /// are retried on the next foreground or when the story is opened.
    static func prepareTodayStory(context: ModelContext) async {
        guard isReady, let language = OnboardingStore.targetLanguage else { return }
        _ = try? await DailyStoryService.ensureTodayStory(context: context, language: language)
    }

    // MARK: - Background

    /// Register the refresh handler. Must run once before launch finishes
    /// (call from `App.init`).
    static func registerBackgroundTask(container: ModelContainer) {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                scheduleNextRefresh()
                let work = Task { @MainActor in await runBackgroundRefresh(context: container.mainContext) }
                refreshTask.expirationHandler = { work.cancel() }
                refreshTask.setTaskCompleted(success: await work.value)
            }
        }
        #endif
    }

    /// Ask iOS to wake us early tomorrow to write the next story. Best-effort —
    /// the system decides when (or whether) to run it.
    static func scheduleNextRefresh(now: Date = .now) {
        #if canImport(BackgroundTasks)
        guard isReady else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        // Already have today's? Aim for just after midnight; otherwise soon.
        let hasToday = OnboardingStore.targetLanguage.map { language in
            UserDefaults.standard.string(forKey: lastStoryDayKey(language)) == DailySetConfig.dayKey(now)
        } ?? false
        request.earliestBeginDate = hasToday ? tomorrow.addingTimeInterval(5 * 60) : now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    private static func runBackgroundRefresh(context: ModelContext, now: Date = .now) async -> Bool {
        guard isReady, let language = OnboardingStore.targetLanguage else { return true }
        let alreadyHad = DailyStoryService.todayStory(context: context, language: language, now: now) != nil
        guard let story = try? await DailyStoryService.ensureTodayStory(context: context, language: language, now: now) else {
            return false
        }
        if !alreadyHad, !story.isOpened {
            await notifyNewStory(story, now: now)
        }
        return true
    }

    private static func lastStoryDayKey(_ language: TargetLanguage) -> String {
        "wordrus.story.lastGeneratedDay.\(language.rawValue)"
    }

    /// Records that `language` has today's story, for `scheduleNextRefresh`.
    static func noteStoryReady(language: TargetLanguage, dayKey: String) {
        UserDefaults.standard.set(dayKey, forKey: lastStoryDayKey(language))
    }

    // MARK: - Notification

    /// "Dr Tusk has a new story", inside the learner's reminder window and
    /// days, and never on top of a word reminder. Skipped (not queued) when
    /// there's no good slot today — the unread row in the Phone tab still
    /// shows it.
    static func notifyNewStory(_ story: DailyStory, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let pending = await center.pendingNotificationRequests()
        let reminderDates = pending.compactMap { request -> Date? in
            guard !request.identifier.hasPrefix(notificationIdentifierPrefix),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
            return trigger.nextTriggerDate()
        }
        guard let fireDate = notificationDate(
            now: now,
            start: OnboardingStore.notificationStart,
            end: OnboardingStore.notificationEnd,
            daysOfWeek: OnboardingStore.notificationDaysOfWeek,
            reminderDates: reminderDates
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Dr Tusk has a new story")
        content.body = String(localized: "“\(story.title)” — tap to listen.")
        content.sound = .default
        content.userInfo = ["kind": notificationKind, "storyID": story.id.uuidString]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = notificationIdentifierPrefix + story.dayKey
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Removes a story's pending notification once it has been opened.
    static func cancelNotification(for story: DailyStory) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationIdentifierPrefix + story.dayKey])
    }

    /// The first moment today, at or after `now`, inside the reminder window
    /// on an allowed weekday and at least `reminderGap` from every reminder.
    /// Checked on a 15-minute grid. nil when today has no such slot.
    static func notificationDate(
        now: Date,
        start: DateComponents,
        end: DateComponents,
        daysOfWeek: Set<Int>,
        reminderDates: [Date],
        calendar: Calendar = .current
    ) -> Date? {
        let days = daysOfWeek.isEmpty ? Set(1...7) : daysOfWeek
        guard days.contains(calendar.component(.weekday, from: now)),
              let windowStart = calendar.date(bySettingHour: start.hour ?? 9, minute: start.minute ?? 0, second: 0, of: now),
              let windowEnd = calendar.date(bySettingHour: end.hour ?? 20, minute: end.minute ?? 0, second: 0, of: now),
              windowEnd > windowStart else { return nil }

        // Round "now" up to the next minute so the trigger is in the future.
        let earliest = calendar.dateInterval(of: .minute, for: now.addingTimeInterval(60))?.start ?? now
        var candidate = max(windowStart, earliest)
        while candidate <= windowEnd {
            if reminderDates.allSatisfy({ abs($0.timeIntervalSince(candidate)) >= reminderGap }) {
                return candidate
            }
            candidate = candidate.addingTimeInterval(15 * 60)
        }
        return nil
    }
}
