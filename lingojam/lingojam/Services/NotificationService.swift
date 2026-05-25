import Foundation
import UserNotifications

enum NotificationService {
    static let defaultStart = DateComponents(hour: 9, minute: 0)
    static let defaultEnd = DateComponents(hour: 20, minute: 0)
    private static let dailyIdentifierPrefix = "lingojam.dailyWord."
    private static let legacyIdentifiers = [
        "lingojam.dailyWord.tomorrow",
        "lingojam.dailyWord.repeating",
    ]

    /// Notification category for walrus call rings — used by
    /// `NotificationDelegate` to route taps into the incoming call screen.
    static let walrusCallCategory = "WALRUS_CALL"
    private static let walrusCallIdentifierPrefix = "lingojam.walter.call."

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
                    content.title = "Walter is calling"
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
}
