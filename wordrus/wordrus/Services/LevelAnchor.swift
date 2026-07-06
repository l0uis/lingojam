import Foundation

/// Shapes a *new-word* candidate pool around the learner's self-assessed CEFR
/// level (`OnboardingStore.cefrLevel`): words at or above that level keep the
/// pool's original order and come first; easier words follow as backfill,
/// nearest band first (a B2 learner backfills B1 before A2 before A1). Never
/// drops a word — when the at-level pool runs dry the easier bands surface
/// instead of the set dead-ending.
///
/// Only unseen-word selection routes through here. Due reviews are exempt by
/// design: once a word is in the learner's rotation its schedule wins,
/// whatever its level.
enum LevelAnchor {
    static func anchored(_ words: [VocabularyWord], to level: CEFRLevel) -> [VocabularyWord] {
        guard level != .a1 else { return words }

        var primary: [VocabularyWord] = []
        var belowByLevel: [CEFRLevel: [VocabularyWord]] = [:]
        for word in words {
            if let raw = word.cefrLevel,
               let wordLevel = CEFRLevel(rawValue: raw),
               wordLevel < level {
                belowByLevel[wordLevel, default: []].append(word)
            } else {
                // At/above the learner's level, or untagged. Untagged means a
                // custom word the user added deliberately — keep it in the
                // primary pool rather than burying it in backfill.
                primary.append(word)
            }
        }

        let backfill = CEFRLevel.allCases
            .filter { $0 < level }
            .sorted(by: >)
            .flatMap { belowByLevel[$0] ?? [] }
        return primary + backfill
    }
}
