import Foundation
import Testing
@testable import wordrus

@MainActor
struct DailyWordServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func word(_ id: String) -> VocabularyWord {
        VocabularyWord(
            id: id,
            rank: 1,
            lemma: id,
            partOfSpeech: "noun",
            definitionsJSON: "{}",
            exampleSentence: "",
            exampleTranslationsJSON: "{}"
        )
    }

    private func snapshot(_ id: String) -> DailyWordSnapshot {
        DailyWordSnapshot(
            wordID: id,
            lemma: id,
            partOfSpeech: "noun",
            definition: "",
            exampleSentence: "",
            exampleTranslation: nil,
            isDueNow: false,
            dueDate: nil,
            computedAt: now
        )
    }

    @Test func knownWordsNeverLeaveTheApp() {
        let words = [word("a"), word("b"), word("c")]
        let known: Set<String> = ["a"]
        #expect(DailyWordService.publishable(words, known: known).map(\.id) == ["b", "c"])
        #expect(DailyWordService.publishable(words, known: []).map(\.id) == ["a", "b", "c"])
        #expect(DailyWordService.publishable(words, known: ["a", "b", "c"]).isEmpty)
    }

    @Test func firstEncounterKnowRetiresTheWord() {
        // SRSScheduler's "I know it" on an unseen word: state .known, no log
        // needed, distant-future due date.
        let progressByID = [
            "a": LearningProgress(wordID: "a", state: .known, dueDate: .distantFuture),
            "b": LearningProgress(wordID: "b", state: .review, dueDate: now.addingTimeInterval(-3600)),
        ]
        let known = DailyWordService.knownIDs(latestRating: [:], progressByID: progressByID, now: now)
        #expect(known == ["a"])
    }

    @Test func knowSwipeOnAlreadySeenWordCountsAsKnown() {
        // The regression: rating .good on a word with a review history leaves
        // it in state .review, not .known — but it sits in the user's Know tab
        // and must stay off the widget until it's due again.
        let progressByID = [
            "a": LearningProgress(wordID: "a", state: .review, dueDate: now.addingTimeInterval(6 * 86_400)),
        ]
        let known = DailyWordService.knownIDs(
            latestRating: ["a": .good],
            progressByID: progressByID,
            now: now
        )
        #expect(known == ["a"])
    }

    @Test func knownWordBecomesEligibleAgainOnceDue() {
        let progressByID = [
            "a": LearningProgress(wordID: "a", state: .review, dueDate: now.addingTimeInterval(-60)),
        ]
        let known = DailyWordService.knownIDs(
            latestRating: ["a": .good],
            progressByID: progressByID,
            now: now
        )
        #expect(known.isEmpty)
    }

    @Test func learningRatingsAreNeverTreatedAsKnown() {
        let progressByID = [
            "a": LearningProgress(wordID: "a", state: .learning, dueDate: now.addingTimeInterval(86_400)),
            "b": LearningProgress(wordID: "b", state: .review, dueDate: now.addingTimeInterval(4 * 86_400)),
        ]
        let known = DailyWordService.knownIDs(
            latestRating: ["a": .again, "b": .hard],
            progressByID: progressByID,
            now: now
        )
        #expect(known.isEmpty)
    }

    @Test func easyCountsAsKnownAndAMissingProgressRowStaysKnown() {
        // Nothing schedules a log-only word back in, so it must not fall
        // through as "due".
        let known = DailyWordService.knownIDs(
            latestRating: ["a": .easy, "b": .good],
            progressByID: [:],
            now: now
        )
        #expect(known == ["a", "b"])
    }

    @Test func pruningDropsWordsMarkedKnownAfterTheSetWasPublished() {
        let set = [snapshot("a"), snapshot("b"), snapshot("c")]
        #expect(DailyWordService.pruning(set, known: ["b"]).map(\.wordID) == ["a", "c"])
        #expect(DailyWordService.pruning(set, known: []).map(\.wordID) == ["a", "b", "c"])
        // Known words from another language / a stale set don't disturb it.
        #expect(DailyWordService.pruning(set, known: ["z"]).map(\.wordID) == ["a", "b", "c"])
        #expect(DailyWordService.pruning(set, known: ["a", "b", "c"]).isEmpty)
    }
}
