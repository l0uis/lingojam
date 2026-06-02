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
            using: snapshot,
            perDay: OnboardingStore.notificationsPerDay,
            start: OnboardingStore.notificationStart,
            end: OnboardingStore.notificationEnd,
            daysOfWeek: OnboardingStore.notificationDaysOfWeek
        )
    }

    static func scheduleReminders(
        using snapshot: DailyWordSnapshot,
        perDay: Int,
        start: DateComponents,
        end: DateComponents,
        daysOfWeek: Set<Int>
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            clearAllPending(center: center) {
                let days = daysOfWeek.isEmpty ? Set(1...7) : daysOfWeek
                let safePerDay = max(1, min(perDay, 64 / max(days.count, 1)))
                let fireTimes = dailyFireTimes(perDay: safePerDay, start: start, end: end)
                for weekday in days.sorted() {
                    for (index, time) in fireTimes.enumerated() {
                        schedule(snapshot: snapshot, weekday: weekday, at: time, index: index, center: center)
                    }
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
        weekday: Int,
        at time: DateComponents,
        index: Int,
        center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Today's word: \(snapshot.lemma)"
        var body = snapshot.definition
        if !snapshot.exampleSentence.isEmpty {
            body += "\n" + snapshot.exampleSentence
        }
        content.body = body
        content.sound = .default

        var components = time
        components.weekday = weekday
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let identifier = "\(dailyIdentifierPrefix)\(weekday).\(index)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func dailyFireTimes(perDay: Int, start: DateComponents, end: DateComponents) -> [DateComponents] {
        let count = max(1, min(perDay, 24))
        let startMinutes = (start.hour ?? 9) * 60 + (start.minute ?? 0)
        let rawEnd = (end.hour ?? 20) * 60 + (end.minute ?? 0)
        let endMinutes = max(rawEnd, startMinutes)
        let span = endMinutes - startMinutes

        guard count > 1 else {
            return [normalizedComponents(fromMinutes: startMinutes)]
        }
        guard span > 0 else {
            return Array(repeating: normalizedComponents(fromMinutes: startMinutes), count: count)
        }

        let step = Double(span) / Double(count - 1)
        return (0..<count).map { i in
            let offset = Int((Double(i) * step).rounded())
            return normalizedComponents(fromMinutes: startMinutes + offset)
        }
    }

    private static func normalizedComponents(fromMinutes total: Int) -> DateComponents {
        let clamped = max(0, min(total, 24 * 60 - 1))
        return DateComponents(hour: clamped / 60, minute: clamped % 60)
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
                    content.body = "Tap to answer and practice your \((OnboardingStore.targetLanguage ?? .spanish).englishName)."
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
