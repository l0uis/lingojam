import Foundation
import SwiftData

enum LearningProgressMigrator {
    /// Retires words that were marked "know" on their first encounter under the
    /// old SRS rules, where a single .good rating left them due again the next day.
    /// Idempotent: skips anything already in the .known state.
    static func retireFirstTimeKnownWords(_ context: ModelContext) {
        let descriptor = FetchDescriptor<LearningProgress>()
        guard let all = try? context.fetch(descriptor) else { return }

        var changed = false
        for progress in all {
            guard progress.state != .known,
                  progress.repetitions == 1,
                  progress.lapses == 0,
                  progress.lastReviewedAt != nil
            else { continue }

            progress.state = .known
            progress.intervalDays = 0
            progress.dueDate = .distantFuture
            changed = true
        }

        if changed { try? context.save() }
    }
}
