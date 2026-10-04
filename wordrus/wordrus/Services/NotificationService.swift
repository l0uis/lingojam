import Foundation
import UserNotifications

enum NotificationService {
    static let defaultStart = DateComponents(hour: 9, minute: 0)
    static let defaultEnd = DateComponents(hour: 20, minute: 0)
    private static let dailyIdentifierPrefix = "wordrus.dailyWord."
    private static let legacyIdentifiers = [
        "wordrus.dailyWord.tomorrow",
        "wordrus.dailyWord.repeating",
    ]

    /// Notification category for walrus call rings — used by
    /// `NotificationDelegate` to route taps into the incoming call screen.
    static let walrusCallCategory = "WALRUS_CALL"
    private static let walrusCallIdentifierPrefix = "wordrus.walter.call."

    /// How many random walrus calls to schedule per week. Kept low so it
    /// feels like a treat, not spam.
    static let walrusCallsPerWeek = 3

    /// How many days ahead daily reminders are scheduled in one batch.
    /// Reminders are re-randomized on every launch (see
    /// `DailyWordService.refresh`), so this only needs to cover a stretch of
    /// days the user might not open the app. Kept at a week so the total
    /// pending count stays well under iOS's 64-notification limit.
    static let reminderHorizonDays = 7

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    static func scheduleDailyReminder(using snapshot: DailyWordSnapshot) {
        scheduleReminders(
            using: reminderStack(fallback: snapshot),
            perDay: OnboardingStore.notificationsPerDay,
            start: OnboardingStore.notificationStart,
            end: OnboardingStore.notificationEnd,
            daysOfWeek: OnboardingStore.notificationDaysOfWeek
        )
    }

    /// Today's ordered word stack for reminders, so consecutive notifications
    /// rotate through different words instead of repeating one. Falls back to
    /// the single stored snapshot before the first set has been built.
    static func reminderStack(fallback snapshot: DailyWordSnapshot?) -> [DailyWordSnapshot] {
        let stack = DailyWordSet.load()?.words ?? []
        if !stack.isEmpty { return stack }
        return snapshot.map { [$0] } ?? []
    }

    static func scheduleReminders(
        using words: [DailyWordSnapshot],
        perDay: Int,
        start: DateComponents,
        end: DateComponents,
        daysOfWeek: Set<Int>
    ) {
        guard !words.isEmpty else {
            cancelAllReminders()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            clearAllPending(center: center) {
                let days = daysOfWeek.isEmpty ? Set(1...7) : daysOfWeek
                // Cap the per-day count so a full week's batch stays well under
                // iOS's 64-notification limit, leaving headroom for walrus calls.
                let safePerDay = max(1, min(perDay, 50 / max(days.count, 1)))
                let fireDates = dailyReminderDates(
                    perDay: safePerDay,
                    start: start,
                    end: end,
                    daysOfWeek: days,
                    from: .now
                )
                // Walk one cursor across every fire slot so the reminders step
                // through the stack in order and never repeat back-to-back
                // (until the stack is exhausted and cycles), mirroring the widget.
                for (index, date) in fireDates.enumerated() {
                    let snapshot = words[index % words.count]
                    schedule(snapshot: snapshot, at: date, index: index, center: center)
                }
            }
        }
    }

    static func cancelAllReminders() {
        let center = UNUserNotificationCenter.current()
        clearAllPending(center: center) {}
    }

    private static func clearAllPending(center: UNUserNotificationCenter, completion: @escaping () -> Void) {
        center.getPendingNotificationRequests { requests in
            var ids = legacyIdentifiers
            ids.append(contentsOf: requests
                .map(\.identifier)
                .filter { $0.hasPrefix(dailyIdentifierPrefix) })
            center.removePendingNotificationRequests(withIdentifiers: ids)
            completion()
        }
    }

    private static func schedule(
        snapshot: DailyWordSnapshot,
        at date: Date,
        index: Int,
        center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = snapshot.lemma
        var body = snapshot.definition
        if !snapshot.exampleSentence.isEmpty {
            body += "\n" + snapshot.exampleSentence
        }
        content.body = body
        content.sound = .default
        // Carry the word id so a tap can surface this exact word (see
        // `NotificationDelegate.didReceive` → `DeepLinkCoordinator`).
        content.userInfo = ["wordID": snapshot.wordID]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        // Non-repeating so each day's fire times can be re-randomized on the
        // next launch instead of locking to a fixed weekly clock time.
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "\(dailyIdentifierPrefix)\(index)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Build concrete future fire dates for the daily reminders across the next
    /// `reminderHorizonDays`. Each allowed day gets `perDay` times chosen at
    /// random within the notification window (see `randomFireMinutes`), so the
    /// reminders land at different clock times each day and are freshly
    /// randomized every time this runs — no more predictable "rings at 9" slot.
    /// Times that have already passed today are dropped. Exposed as `internal`
    /// for unit testing.
    static func dailyReminderDates(
        perDay: Int,
        start: DateComponents,
        end: DateComponents,
        daysOfWeek: Set<Int>,
        from anchor: Date
    ) -> [Date] {
        let days = daysOfWeek.isEmpty ? Set(1...7) : daysOfWeek
        let cal = Calendar.current
        let count = max(1, min(perDay, 24))
        let startMinutes = (start.hour ?? 9) * 60 + (start.minute ?? 0)
        let rawEnd = (end.hour ?? 20) * 60 + (end.minute ?? 0)
        let endMinutes = max(rawEnd, startMinutes)
        let span = endMinutes - startMinutes

        var dates: [Date] = []
        for dayOffset in 0..<reminderHorizonDays {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: anchor) else { continue }
            guard days.contains(cal.component(.weekday, from: day)) else { continue }
            for minutes in randomFireMinutes(count: count, startMinutes: startMinutes, span: span) {
                guard let fire = cal.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: day
                ), fire > anchor else { continue }
                dates.append(fire)
            }
        }
        return dates.sorted()
    }

    /// Pick `count` minute-of-day values within `[startMinutes, startMinutes +
    /// span]`. The window is split into `count` equal buckets and one random
    /// minute is drawn from each, so the times stay spread across the window
    /// (never clustered) while still varying run to run. Returned sorted.
    /// Exposed as `internal` for unit testing.
    static func randomFireMinutes(count: Int, startMinutes: Int, span: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard span > 0 else { return Array(repeating: startMinutes, count: count) }
        let bucket = Double(span) / Double(count)
        return (0..<count).map { i in
            let lo = Int((Double(i) * bucket).rounded(.down))
            let hi = Int((Double(i + 1) * bucket).rounded(.down))
            let offset = hi > lo ? Int.random(in: lo..<hi) : lo
            return startMinutes + min(offset, span)
        }
    }

    // MARK: - Walrus calls

    /// Cancel any pending walrus calls and schedule a fresh batch over the
    /// next 7 days. Picks random days from the user's allowed days and
    /// random fire times within the user's notification window. Persists
    /// the fire dates so `MissedCallReconciler` can detect calls that
    /// rang but were never answered.
    static func scheduleWalrusCalls() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            cancelWalrusCalls(center: center) {
                let fireDates = pickWalrusCallDates(
                    count: walrusCallsPerWeek,
                    start: OnboardingStore.notificationStart,
                    end: OnboardingStore.notificationEnd,
                    daysOfWeek: OnboardingStore.notificationDaysOfWeek,
                    from: .now
                )

                OnboardingStore.scheduledWalterCallDates = fireDates

                for (index, date) in fireDates.enumerated() {
                    let content = UNMutableNotificationContent()
                    content.title = "Dr Tusk is calling"
                    content.body = "Tap to answer and practice your \((OnboardingStore.targetLanguage ?? .spanish).title)."
                    content.sound = .default
                    content.categoryIdentifier = walrusCallCategory
                    content.userInfo = ["kind": walrusCallCategory]

                    let components = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: date
                    )
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let identifier = "\(walrusCallIdentifierPrefix)\(index)"
                    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                }
            }
        }
    }

    static func cancelWalrusCalls() {
        cancelWalrusCalls(center: UNUserNotificationCenter.current()) {}
    }

    private static func cancelWalrusCalls(
        center: UNUserNotificationCenter,
        completion: @escaping () -> Void
    ) {
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(walrusCallIdentifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            completion()
        }
    }

    /// Pick `count` random fire dates spread across the next 7 days.
    /// Days are chosen randomly from the user's allowed weekdays; times
    /// are chosen uniformly within the notification window. Exposed as
    /// `internal` for unit testing.
    static func pickWalrusCallDates(
        count: Int,
        start: DateComponents,
        end: DateComponents,
        daysOfWeek: Set<Int>,
        from anchor: Date
    ) -> [Date] {
        let days = daysOfWeek.isEmpty ? Set(1...7) : daysOfWeek
        let cal = Calendar.current
        let startMinutes = (start.hour ?? 9) * 60 + (start.minute ?? 0)
        let rawEnd = (end.hour ?? 20) * 60 + (end.minute ?? 0)
        let endMinutes = max(rawEnd, startMinutes + 1)
        let span = endMinutes - startMinutes

        var picks: [Date] = []
        var attempts = 0
        while picks.count < count, attempts < count * 12 {
            attempts += 1
            let dayOffset = Int.random(in: 1...7)
            guard let candidateDay = cal.date(byAdding: .day, value: dayOffset, to: anchor) else { continue }
            let weekday = cal.component(.weekday, from: candidateDay)
            guard days.contains(weekday) else { continue }
            let offset = Int.random(in: 0..<span)
            let totalMinutes = startMinutes + offset
            guard let fire = cal.date(
                bySettingHour: totalMinutes / 60,
                minute: totalMinutes % 60,
                second: 0,
                of: candidateDay
            ), fire > anchor else { continue }
            picks.append(fire)
        }
        return picks.sorted()
    }

    // MARK: - Trial-ending reminder

    private static let trialReminderIdentifier = "wordrus.trial.endingReminder"

    /// Schedule a one-off local notification reminding the user their free
    /// trial is about to convert to a paid subscription. Fires `daysBeforeEnd`
    /// days before the trial ends (default 1), around 10am. Requests
    /// notification authorization if needed; no-ops if the user declines.
    /// Call when a trial purchase succeeds and the user opted in.
    static func scheduleTrialEndingReminder(trialDays: Int, daysBeforeEnd: Int = 1) async {
        guard await requestAuthorization() else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [trialReminderIdentifier])

        let cal = Calendar.current
        let leadDays = max(trialDays - daysBeforeEnd, 0)
        guard let day = cal.date(byAdding: .day, value: leadDays, to: .now) else { return }
        var components = cal.dateComponents([.year, .month, .day], from: day)
        components.hour = 10
        components.minute = 0

        let trigger: UNNotificationTrigger
        if let fireDate = cal.date(from: components), fireDate > .now {
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            // Trial too short for a future 10am slot — remind in an hour.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        }

        let content = UNMutableNotificationContent()
        content.title = "Your free trial is ending"
        content.body = "Your Wordrus Pro trial ends soon. Cancel anytime if it's not for you."
        content.sound = .default

        try? await center.add(UNNotificationRequest(
            identifier: trialReminderIdentifier,
            content: content,
            trigger: trigger
        ))
    }

    static func cancelTrialEndingReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [trialReminderIdentifier])
    }
}
