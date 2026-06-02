import Foundation
import Testing
@testable import wordrus

@MainActor
struct SRSSchedulerTests {
    @Test func firstTimeGoodRetiresTheWord() {
        let progress = LearningProgress(wordID: "test-1")
        let result = SRSScheduler.next(progress: progress, rating: .good)
        #expect(result.state == .known)
        #expect(result.dueDate == .distantFuture)
        #expect(result.repetitions == 1)
    }

    @Test func goodOnPreviouslyReviewedWordFollowsSRS() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = LearningProgress(
            wordID: "test-1b",
            state: .learning,
            intervalDays: 1,
            repetitions: 0,
            lapses: 1,
            lastReviewedAt: now.addingTimeInterval(-86_400)
        )
        let result = SRSScheduler.next(progress: progress, rating: .good, now: now)
        #expect(result.state != .known)
        #expect(result.intervalDays == 1)
        #expect(result.repetitions == 1)
    }

    @Test func newCardWithEasyAdvancesToFourDays() {
        let progress = LearningProgress(wordID: "test-2")
        let result = SRSScheduler.next(progress: progress, rating: .easy)
        #expect(result.intervalDays == 4)
        #expect(result.state == .review)
    }

    @Test func secondGoodAdvancesToSixDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = LearningProgress(
            wordID: "test-3",
            state: .learning,
            intervalDays: 1,
            repetitions: 1,
            lastReviewedAt: now.addingTimeInterval(-86_400)
        )
        let result = SRSScheduler.next(progress: progress, rating: .good, now: now)
        #expect(result.intervalDays == 6)
        #expect(result.repetitions == 2)
        #expect(result.state == .review)
    }

    @Test func againResetsRepetitionsAndReducesEase() {
        let progress = LearningProgress(
            wordID: "test-4",
            state: .review,
            easeFactor: 2.5,
            intervalDays: 30,
            repetitions: 5
        )
        let result = SRSScheduler.next(progress: progress, rating: .again)
        #expect(result.intervalDays == 1)
        #expect(result.repetitions == 0)
        #expect(result.easeFactor == 2.3)
        #expect(result.lapses == 1)
        #expect(result.state == .learning)
    }

    @Test func easeFactorFloorsAt1_3() {
        let progress = LearningProgress(
            wordID: "test-5",
            state: .review,
            easeFactor: 1.4,
            intervalDays: 10,
            repetitions: 3
        )
        let result = SRSScheduler.next(progress: progress, rating: .again)
        #expect(result.easeFactor == 1.3)
    }

    @Test func goodAfterReviewMultipliesByEase() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = LearningProgress(
            wordID: "test-6",
            state: .review,
            easeFactor: 2.5,
            intervalDays: 6,
            repetitions: 2,
            lastReviewedAt: now.addingTimeInterval(-6 * 86_400)
        )
        let result = SRSScheduler.next(progress: progress, rating: .good, now: now)
        #expect(result.intervalDays == 15)
        #expect(result.repetitions == 3)
    }

    @Test func dueDateIsSetIntoTheFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = LearningProgress(wordID: "test-7")
        let result = SRSScheduler.next(progress: progress, rating: .easy, now: now)
        let expected = Calendar.current.date(byAdding: .day, value: 4, to: now)!
        #expect(result.dueDate == expected)
        #expect(result.lastReviewedAt == now)
    }
}
