import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app (which starts/updates the activity) and the widget
/// extension (which renders it). The activity carries no fixed metadata; the
/// current word lives entirely in the dynamic `ContentState` so it can rotate
/// through the day.
struct WordActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The word currently shown on the Lock Screen / Dynamic Island.
        var snapshot: DailyWordSnapshot
        /// Position within today's set — drives the "n of total" affordance.
        var index: Int
        var total: Int
    }
}
#endif
