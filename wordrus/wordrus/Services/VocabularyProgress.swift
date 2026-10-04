import Foundation

/// A vocabulary size worth celebrating. Phrased as encouragement — what the
/// learner is ready to *try* — never as a guarantee.
struct Milestone: Identifiable, Equatable {
    let count: Int
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    var id: Int { count }

    static func == (lhs: Milestone, rhs: Milestone) -> Bool { lhs.count == rhs.count }
}

enum Milestones {
    /// Ascending by `count`. Kept here (not in views) so the ladder can be
    /// tuned in one place; the copy goes through the String Catalog.
    static let all: [Milestone] = [
        Milestone(count: 50, title: "Your first 50 words",
                  detail: "A real start — greetings and the basics are yours.",
                  systemImage: "leaf.fill"),
        Milestone(count: 150, title: "Order at a café",
                  detail: "You're ready to try ordering a coffee and a snack.",
                  systemImage: "cup.and.saucer.fill"),
        Milestone(count: 300, title: "Find your way",
                  detail: "Ready to try asking for directions — and following the answer.",
                  systemImage: "map.fill"),
        Milestone(count: 500, title: "Small talk",
                  detail: "Enough to try chatting about the weather, family and your day.",
                  systemImage: "bubble.left.and.bubble.right.fill"),
        Milestone(count: 1000, title: "Everyday situations",
                  detail: "Shops, trains, the doctor — you're ready to try most daily errands.",
                  systemImage: "bag.fill"),
        Milestone(count: 1500, title: "Follow a simple podcast",
                  detail: "Ready to try a slow podcast made for learners.",
                  systemImage: "headphones"),
        Milestone(count: 2500, title: "Read a simple book",
                  detail: "Ready to try a graded reader from cover to cover.",
                  systemImage: "book.fill"),
        Milestone(count: 4000, title: "Talk about almost anything",
                  detail: "Ready to try conversations that wander anywhere.",
                  systemImage: "sparkles"),
    ]
}

/// Where the learner stands on the milestone ladder.
struct MilestoneStatus: Equatable {
    /// The highest milestone reached, if any.
    let reached: Milestone?
    /// The next one to aim for; nil once every milestone is reached.
    let next: Milestone?
    /// Progress from `reached` (or zero) to `next`, 0…1. 1 when all are reached.
    let fraction: Double
    /// Words still to learn to reach `next`.
    let remaining: Int
}

/// Pure progress maths for the Vocabulary tab header — no SwiftData, so it's
/// unit-testable.
enum VocabularyProgress {
    /// The Know / Learning rule shared by the Vocabulary list and its
    /// header: the latest rating decides (good/easy → Know, again/hard →
    /// Learning); without a rating, a word that's been swiped "don't know"
    /// or is in the learning/review state is Learning. Unreviewed words are
    /// in neither.
    static func isKnown(_ wordID: String, ratings: [String: ReviewRating]) -> Bool {
        guard let rating = ratings[wordID] else { return false }
        return rating == .good || rating == .easy
    }

    static func isLearning(_ wordID: String, ratings: [String: ReviewRating], progress: LearningProgress?) -> Bool {
        if let rating = ratings[wordID] { return rating == .again || rating == .hard }
        guard let progress else { return false }
        return progress.lapses > 0 || progress.state == .learning || progress.state == .review
    }

    static func milestoneStatus(learned: Int, milestones: [Milestone] = Milestones.all) -> MilestoneStatus {
        let reached = milestones.last { $0.count <= learned }
        guard let next = milestones.first(where: { $0.count > learned }) else {
            return MilestoneStatus(reached: reached, next: nil, fraction: 1, remaining: 0)
        }
        let base = reached?.count ?? 0
        let fraction = Double(learned - base) / Double(next.count - base)
        return MilestoneStatus(reached: reached, next: next, fraction: min(max(fraction, 0), 1), remaining: next.count - learned)
    }

    /// Share of everyday language the learned words cover: each ranked seed
    /// lemma weighs 1/rank (Zipf's law — the 10th most common word turns up
    /// about ten times as often as the 100th), out of every ranked lemma.
    /// Unranked words (custom ones) don't count either way.
    static func coverage(learnedLemmas: Set<String>, ranks: [String: Int]) -> Double {
        guard !ranks.isEmpty else { return 0 }
        var total = 0.0
        var known = 0.0
        for (lemma, rank) in ranks where rank > 0 {
            let weight = 1 / Double(rank)
            total += weight
            if learnedLemmas.contains(lemma) { known += weight }
        }
        return total > 0 ? known / total : 0
    }

    struct TopicFill: Identifiable, Equatable {
        let slug: String
        let name: String
        let systemImage: String
        let learned: Int
        let total: Int
        var id: String { slug }
        var fraction: Double { total > 0 ? Double(learned) / Double(total) : 0 }
    }

    /// Learned / total seed words per visible deck, in deck order.
    static func topicFills(
        words: [(id: String, decks: [String])],
        learnedIDs: Set<String>,
        decks: [(slug: String, name: String, systemImage: String)]
    ) -> [TopicFill] {
        var totals: [String: Int] = [:]
        var learned: [String: Int] = [:]
        for word in words {
            for slug in word.decks {
                totals[slug, default: 0] += 1
                if learnedIDs.contains(word.id) { learned[slug, default: 0] += 1 }
            }
        }
        return decks.compactMap { deck in
            guard let total = totals[deck.slug], total > 0 else { return nil }
            return TopicFill(slug: deck.slug, name: deck.name, systemImage: deck.systemImage,
                             learned: learned[deck.slug] ?? 0, total: total)
        }
    }

    /// Known word IDs in the order they were learned: by the first good/easy
    /// rating each one got. `logs` may be in any order.
    static func learnedOrder(knownIDs: Set<String>, logs: [(wordID: String, date: Date, rating: ReviewRating)]) -> [String] {
        var firstKnown: [String: Date] = [:]
        for log in logs where knownIDs.contains(log.wordID) && (log.rating == .good || log.rating == .easy) {
            if let existing = firstKnown[log.wordID], existing <= log.date { continue }
            firstKnown[log.wordID] = log.date
        }
        return knownIDs.sorted { lhs, rhs in
            let l = firstKnown[lhs] ?? .distantFuture
            let r = firstKnown[rhs] ?? .distantFuture
            return l == r ? lhs < rhs : l < r
        }
    }
}

extension StoryLexicon {
    @MainActor private static var rankCache: [String: [String: Int]] = [:]

    /// Frequency ranks for a language, loaded once per launch.
    @MainActor
    static func cachedFrequencyRanks(for language: TargetLanguage) -> [String: Int] {
        if let cached = rankCache[language.languageCode] { return cached }
        let ranks = load(for: language)?.frequencyRanks() ?? [:]
        rankCache[language.languageCode] = ranks
        return ranks
    }
}
