import Foundation
import Testing
@testable import wordrus

@MainActor
struct VocabularyProgressTests {
    // MARK: Milestones

    @Test func milestonesAscendAndStartWithTheSpecLadder() {
        let counts = Milestones.all.map(\.count)
        #expect(counts == counts.sorted())
        #expect(Set(counts).count == counts.count)
        for required in [150, 500, 1000, 1500] {
            #expect(counts.contains(required))
        }
    }

    @Test func statusBeforeTheFirstMilestone() {
        let status = VocabularyProgress.milestoneStatus(learned: 0)
        #expect(status.reached == nil)
        #expect(status.next?.count == 50)
        #expect(status.remaining == 50)
        #expect(status.fraction == 0)

        let almost = VocabularyProgress.milestoneStatus(learned: 49)
        #expect(almost.reached == nil)
        #expect(almost.remaining == 1)
        #expect(abs(almost.fraction - 0.98) < 1e-9)
    }

    @Test func reachingAMilestoneRestartsTheBarTowardsTheNext() {
        let status = VocabularyProgress.milestoneStatus(learned: 150)
        #expect(status.reached?.count == 150)
        #expect(status.next?.count == 300)
        #expect(status.fraction == 0)
        #expect(status.remaining == 150)

        let halfway = VocabularyProgress.milestoneStatus(learned: 225)
        #expect(abs(halfway.fraction - 0.5) < 1e-9)
    }

    @Test func pastTheLastMilestoneTheBarIsFull() {
        let status = VocabularyProgress.milestoneStatus(learned: 10_000)
        #expect(status.reached?.count == Milestones.all.last?.count)
        #expect(status.next == nil)
        #expect(status.fraction == 1)
        #expect(status.remaining == 0)
    }

    // MARK: Coverage

    @Test func coverageWeighsFrequentWordsMore() {
        let ranks = ["ser": 1, "casa": 2, "perro": 3, "raro": 4]
        let total = 1.0 + 1.0 / 2 + 1.0 / 3 + 1.0 / 4
        #expect(VocabularyProgress.coverage(learnedLemmas: [], ranks: ranks) == 0)
        #expect(abs(VocabularyProgress.coverage(learnedLemmas: ["ser"], ranks: ranks) - 1 / total) < 1e-9)
        // The most common word is worth more than the rarest one.
        #expect(VocabularyProgress.coverage(learnedLemmas: ["ser"], ranks: ranks)
                > VocabularyProgress.coverage(learnedLemmas: ["raro"], ranks: ranks))
        #expect(abs(VocabularyProgress.coverage(learnedLemmas: Set(ranks.keys), ranks: ranks) - 1) < 1e-9)
    }

    @Test func unrankedWordsDontCountAndNoDataMeansZero() {
        #expect(VocabularyProgress.coverage(learnedLemmas: ["custom"], ranks: ["ser": 1]) == 0)
        #expect(VocabularyProgress.coverage(learnedLemmas: ["ser"], ranks: [:]) == 0)
    }

    @Test func realLexiconCoverageIsSensible() throws {
        let ranks = try #require(StoryLexicon.load(languageCode: "es")).frequencyRanks()
        let top100 = Set(ranks.filter { $0.value <= 100 }.keys)
        let coverage = VocabularyProgress.coverage(learnedLemmas: top100, ranks: ranks)
        // Zipf: the 100 most common content words cover roughly half.
        #expect(coverage > 0.4 && coverage < 0.7)
    }

    @Test func coverageTextRoundsDownAndNeverSaysZeroForAFewWords() {
        func text(_ coverage: Double) -> String {
            VocabularySnapshot(learnedCount: 0, status: VocabularyProgress.milestoneStatus(learned: 0),
                               coverage: coverage, topics: [], learnedInOrder: []).coverageText
        }
        #expect(text(0.349).hasPrefix("~34"))
        #expect(text(0.004).hasPrefix("<1"))
        #expect(text(0).hasPrefix("0"))
    }

    // MARK: Topics

    @Test func topicFillsCountLearnedWordsPerDeckInDeckOrder() {
        let fills = VocabularyProgress.topicFills(
            words: [("a", ["animals"]), ("b", ["animals", "home"]), ("c", ["home"]), ("d", ["home"])],
            learnedIDs: ["b", "c"],
            decks: [("home", "Home", "house.fill"), ("animals", "Animals", "pawprint.fill"), ("empty", "Empty", "x")]
        )
        #expect(fills.map(\.slug) == ["home", "animals"])
        #expect(fills[0].learned == 2 && fills[0].total == 3)
        #expect(fills[1].learned == 1 && fills[1].total == 2)
        #expect(fills[1].fraction == 0.5)
    }

    // MARK: Learned order & Know rule

    @Test func learnedOrderUsesTheFirstKnowRating() {
        let t = { (s: TimeInterval) in Date(timeIntervalSince1970: s) }
        let order = VocabularyProgress.learnedOrder(
            knownIDs: ["a", "b", "c"],
            logs: [
                ("a", t(300), .good),
                ("b", t(100), .again),   // a miss doesn't count as learning it
                ("b", t(200), .easy),
                ("c", t(50), .good),
                ("c", t(400), .good),    // later re-reviews don't move it
                ("x", t(10), .good),     // not known any more
            ]
        )
        #expect(order == ["c", "b", "a"])
    }

    @Test func knowRuleMatchesTheVocabularyTabs() {
        let ratings: [String: ReviewRating] = ["k": .good, "e": .easy, "l": .again, "h": .hard]
        #expect(VocabularyProgress.isKnown("k", ratings: ratings))
        #expect(VocabularyProgress.isKnown("e", ratings: ratings))
        #expect(!VocabularyProgress.isKnown("l", ratings: ratings))
        #expect(VocabularyProgress.isLearning("h", ratings: ratings, progress: nil))
        #expect(!VocabularyProgress.isLearning("k", ratings: ratings, progress: nil))
        // No rating: a lapsed or in-review word is Learning; an untouched one is neither.
        #expect(VocabularyProgress.isLearning("x", ratings: [:], progress: LearningProgress(wordID: "x", lapses: 1)))
        #expect(!VocabularyProgress.isLearning("y", ratings: [:], progress: LearningProgress(wordID: "y")))
        #expect(!VocabularyProgress.isKnown("y", ratings: [:]))
    }
}
