import Foundation
import SwiftData

/// Keeps the on-device database in sync with the bundled seed for decks and
/// words. Runs every launch; all operations are idempotent.
///   - Inserts any deck that isn't already in the database.
///   - Inserts any new vocabulary word that wasn't in a prior seed.
///   - Updates deck membership for existing words (so adding a tag in the
///     seed propagates to already-seeded installs).
///   - Backfills empty membership to ["common"] for legacy rows.
///   - Deletes seeded words the current seed no longer ships (vetted-out
///     junk). Custom words are the user's own and are never touched; a
///     removed word's LearningProgress row stays behind, orphaning harmlessly
///     (and rebinding if the word ever returns to the seed).
enum DeckSyncMigrator {
    static func sync(_ context: ModelContext) {
        guard let seed = SeedDataLoader.loadSeed() else { return }

        var changed = false
        let encoder = JSONEncoder()

        // Decks
        let existingDecks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        let existingDeckBySlug = Dictionary(uniqueKeysWithValues: existingDecks.map { ($0.slug, $0) })
        for seedDeck in seed.decks ?? [] {
            if existingDeckBySlug[seedDeck.slug] == nil {
                context.insert(SeedDataLoader.makeDeck(seedDeck))
                changed = true
            }
        }

        // Words
        let existingWords = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let existingWordByID = Dictionary(uniqueKeysWithValues: existingWords.map { ($0.id, $0) })

        for seedWord in seed.words {
            let seedSlugs = seedWord.decks ?? [DeckConstants.commonSlug]
            if let existing = existingWordByID[seedWord.id] {
                let current = existing.deckSlugs
                let merged = mergeUnique(current, with: seedSlugs)
                if merged != current {
                    existing.setDeckSlugs(merged)
                    changed = true
                }
                // Backfill cefrLevel if the seed now has one and the row doesn't.
                if existing.cefrLevel == nil, let level = seedWord.cefrLevel {
                    existing.cefrLevel = level
                    changed = true
                }
            } else {
                context.insert(SeedDataLoader.makeWord(seedWord, encoder: encoder))
                changed = true
            }
        }

        // Legacy rows that predate deckSlugsJSON: tag with "common".
        for word in existingWords where word.deckSlugs.isEmpty {
            word.setDeckSlugs([DeckConstants.commonSlug])
            changed = true
        }

        // Seeded words removed from the bundled seed (vetting blocklist).
        // Scoped to ids of the seed's own language so the Spanish-fallback
        // path in `loadSeed` (missing seed file) can never mass-delete
        // another language's rows.
        let seedIDs = Set(seed.words.map(\.id))
        let seedPrefix = "\(seed.language)-"
        for word in existingWords
        where word.id.hasPrefix(seedPrefix) && !seedIDs.contains(word.id) {
            context.delete(word)
            changed = true
        }

        if changed { try? context.save() }
    }

    private static func mergeUnique(_ a: [String], with b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for slug in a + b where seen.insert(slug).inserted {
            result.append(slug)
        }
        return result
    }
}
