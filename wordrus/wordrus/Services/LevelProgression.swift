import Foundation
import SwiftData

/// Level-up progression. A learner advances to the next CEFR level by EITHER
/// of two paths, whichever they reach first:
///   • Vocabulary: mark `knownWordsNeeded(toLeave:)` words *at their current
///     level* as Known through daily practice.
///   • Conversation: pass `passingCallsNeeded(toLeave:)` Walter calls (tracked
///     by `OnboardingStore.cefrPassesAtCurrentLevel`).
///
/// Both thresholds scale per level rather than being flat. The vocabulary bank
/// is a bell curve — shallow at A1, deepest around B1, near-empty at C1/C2 —
/// and `LevelAnchor` only ever backfills *downward*, so leveling up raises the
/// ceiling without hiding easier words. The thresholds therefore peak through
/// the fat middle (B1→B2) and taper at the thin top, tracking how much content
/// each level actually holds.
///
/// The level itself is the per-language active value in `OnboardingStore`
/// (see `LevelAnchor`, which uses it to shape the new-word pool). Promotion
/// resets the call counter; the vocabulary counter resets organically because
/// it only counts words tagged at the *new* current level.
enum LevelProgression {
    /// Mastered words at `level` required to advance out of it.
    static func knownWordsNeeded(toLeave level: CEFRLevel) -> Int {
        switch level {
        case .a1: return 80
        case .a2: return 150
        case .b1: return 200
        case .b2: return 150
        case .c1: return 60
        case .c2: return .max   // top of the ladder — nothing to advance to
        }
    }

    /// Passing Walter calls at `level` required to advance out of it.
    static func passingCallsNeeded(toLeave level: CEFRLevel) -> Int {
        switch level {
        case .a1: return 3
        case .a2: return 4
        case .b1: return 5
        case .b2: return 5
        case .c1: return 4
        case .c2: return .max
        }
    }

    struct Status {
        let level: CEFRLevel
        let next: CEFRLevel?
        let knownAtLevel: Int
        let passes: Int

        var knownNeeded: Int { knownWordsNeeded(toLeave: level) }
        var passesNeeded: Int { passingCallsNeeded(toLeave: level) }

        /// At the top of the ladder there is nothing to progress toward.
        var isMaxLevel: Bool { next == nil }

        var eligible: Bool {
            next != nil && (knownAtLevel >= knownNeeded || passes >= passesNeeded)
        }

        /// 0…1 progress along whichever path is furthest along.
        var fraction: Double {
            guard next != nil else { return 1 }
            let byWords = Double(min(knownAtLevel, knownNeeded)) / Double(knownNeeded)
            let byCalls = Double(min(passes, passesNeeded)) / Double(passesNeeded)
            return max(byWords, byCalls)
        }

        /// One-line description of the shortest remaining route to `next`.
        func summary() -> String {
            guard let next else { return "You're at the top level." }
            if eligible { return "Ready to move up to \(next.title)." }
            let wordsLeft = max(0, knownNeeded - knownAtLevel)
            let callsLeft = max(0, passesNeeded - passes)
            let byWords = Double(knownAtLevel) / Double(knownNeeded)
            let byCalls = Double(passes) / Double(passesNeeded)
            if byCalls >= byWords, passes > 0 {
                return "\(next.title) in \(callsLeft) more \(callsLeft == 1 ? "call" : "calls")."
            }
            return "\(next.title) in \(wordsLeft) more mastered \(wordsLeft == 1 ? "word" : "words")."
        }
    }

    @MainActor
    static func status(context: ModelContext) -> Status {
        let level = OnboardingStore.cefrLevel
        let passes = OnboardingStore.cefrPassesAtCurrentLevel
        let languageCode = (OnboardingStore.targetLanguage ?? .spanish).languageCode

        let allProgress = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let knownIDs = Set(allProgress.filter { $0.state == .known }.map(\.wordID))

        let allWords = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let knownAtLevel = allWords.scoped(to: languageCode).filter {
            $0.cefrLevel == level.rawValue && knownIDs.contains($0.id)
        }.count

        return Status(level: level, next: level.next, knownAtLevel: knownAtLevel, passes: passes)
    }

    /// Advance to the next level and reset the call counter. No-op at the top.
    @MainActor
    static func promote() {
        guard let next = OnboardingStore.cefrLevel.next else { return }
        OnboardingStore.cefrLevel = next
        OnboardingStore.cefrPassesAtCurrentLevel = 0
    }
}
