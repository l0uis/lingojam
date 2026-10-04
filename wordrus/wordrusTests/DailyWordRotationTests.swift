import Foundation
import Testing
@testable import wordrus

struct DailyWordRotationTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func intervalClampsBetweenOneAndThreeHours() {
        // Large set → clamped to the 1h floor (12h/24 = 0.5h < 1h).
        #expect(DailyWordRotation.interval(count: 24) == 3600)
        // Small set → clamped to the 3h ceiling (12h/2 = 6h > 3h).
        #expect(DailyWordRotation.interval(count: 2) == 3 * 3600)
        // Mid set → the spread value itself (12h/6 = 2h).
        #expect(DailyWordRotation.interval(count: 6) == 2 * 3600)
        // Degenerate empty set must not divide by zero.
        #expect(DailyWordRotation.interval(count: 0) == 3 * 3600)
    }

    @Test func indexAdvancesEachIntervalAndWraps() {
        let count = 4                      // interval = 3h (12h/4)
        let ivl = DailyWordRotation.interval(count: count)
        #expect(ivl == 3 * 3600)
        #expect(DailyWordRotation.index(at: start, count: count, since: start) == 0)
        #expect(DailyWordRotation.index(at: start.addingTimeInterval(ivl - 1), count: count, since: start) == 0)
        #expect(DailyWordRotation.index(at: start.addingTimeInterval(ivl), count: count, since: start) == 1)
        #expect(DailyWordRotation.index(at: start.addingTimeInterval(3 * ivl), count: count, since: start) == 3)
        // Wrap-around back to 0 after a full cycle.
        #expect(DailyWordRotation.index(at: start.addingTimeInterval(4 * ivl), count: count, since: start) == 0)
    }

    @Test func indexIsZeroBeforeComputedAtAndForEmptySet() {
        #expect(DailyWordRotation.index(at: start.addingTimeInterval(-10_000), count: 5, since: start) == 0)
        #expect(DailyWordRotation.index(at: start, count: 0, since: start) == 0)
    }

    @Test func nextBoundaryIsTheUpcomingIntervalEdge() {
        let count = 3                      // interval = 3h (clamped)
        let ivl = DailyWordRotation.interval(count: count)
        #expect(DailyWordRotation.nextBoundary(at: start, count: count, since: start) == start.addingTimeInterval(ivl))
        #expect(DailyWordRotation.nextBoundary(at: start.addingTimeInterval(ivl + 60), count: count, since: start) == start.addingTimeInterval(2 * ivl))
    }
}
