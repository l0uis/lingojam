import Foundation
import SwiftData

/// Runs on app launch to detect scheduled walrus call notifications that
/// fired but were never answered. For each one, writes a missed-call
/// `ChatSession` and trims it from the pending list.
///
/// Caveat: this only covers the case where the user eventually opens the
/// app. If they ignore notifications forever the missed-call records
/// catch up the next time they launch — fine for an MVP.
enum MissedCallReconciler {
    /// Window after a scheduled fire date during which an actual chat
    /// session "counts" as answering that ring. 30 minutes is generous
    /// enough that a user who answered a few minutes late won't get a
    /// spurious missed call written.
    static let answerWindow: TimeInterval = 30 * 60

    static func reconcileIfNeeded(_ context: ModelContext) {
        let now = Date.now
        let scheduled = OnboardingStore.scheduledWalterCallDates
        guard !scheduled.isEmpty else { return }

        let past = scheduled.filter { $0 <= now }
        if past.isEmpty { return }

        // Pull recent sessions to check whether each ring was answered.
        let cutoff = past.min() ?? now
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.startedAt >= cutoff }
        )
        let recent = (try? context.fetch(descriptor)) ?? []

        var inserted = 0
        for fireDate in past {
            let wasAnswered = recent.contains { session in
                abs(session.startedAt.timeIntervalSince(fireDate)) <= answerWindow
            }
            if !wasAnswered {
                ChatStore.recordTerminalSession(
                    context: context,
                    status: .missed,
                    wasIncoming: true,
                    at: fireDate
                )
                inserted += 1
            }
        }

        if inserted > 0 {
            try? context.save()
        }

        // Keep only future fire dates.
        OnboardingStore.scheduledWalterCallDates = scheduled.filter { $0 > now }
    }
}
