import Foundation
import SwiftData

struct SeedFile: Decodable {
    let version: Int
    let language: String
    let decks: [SeedDeck]?
    let words: [SeedWord]
}

struct SeedDeck: Decodable {
    let slug: String
    let displayName: String
    let description: String?
    let icon: String?
    let sortOrder: Int?
}

struct SeedWord: Decodable {
    let id: String
    let rank: Int
    let lemma: String
    let partOfSpeech: String
    let definitions: [String: String]
    let example: SeedExample
    let decks: [String]?
    let cefrLevel: String?
}

/// The example sentence in the target language plus translations keyed by
/// locale (currently always `en`). Pre-v3 seeds stored the sentence under
/// the `es` key; v3+ uses the neutral `text` key so the loader doesn't
/// need to branch on language.
struct SeedExample: Decodable {
    let text: String
    let translations: [String: String]

    private enum CodingKeys: String, CodingKey {
        case text
        case translations
        case es
        case fr
        case it
        case de
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.translations = try container.decode([String: String].self, forKey: .translations)
        if let neutral = try container.decodeIfPresent(String.self, forKey: .text) {
            self.text = neutral
        } else if let es = try container.decodeIfPresent(String.self, forKey: .es) {
            self.text = es
        } else if let fr = try container.decodeIfPresent(String.self, forKey: .fr) {
            self.text = fr
        } else if let it = try container.decodeIfPresent(String.self, forKey: .it) {
            self.text = it
        } else if let de = try container.decodeIfPresent(String.self, forKey: .de) {
            self.text = de
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "Seed example must include text or a language-coded sentence."
            )
        }
    }
}

enum SeedDataLoader {
    /// Bumped whenever the bundled seeds' deck taxonomy changes. On launch,
    /// installs with a lower stored version run `migrateDeckTaxonomy` to
    /// remap word tags and refresh the Deck records without wiping progress.
    static let currentDeckTaxonomyVersion = 3

    /// Old slugs that need to be renamed in existing word data when migrating
    /// from an earlier deck taxonomy. Keep entries here forever (or until you
    /// stop supporting upgrades from that older version).
    private static let deckSlugRemap: [String: String] = [
        "travel": "traveling",
        "food": "food-and-drink",
        "work": "work-and-money",
        "money_shopping": "shopping",
        "body_health": "health",
        "nature_weather": "traveling",
    ]

    /// Old slugs to remove entirely when migrating. Words remain (they still
    /// have `common`/are visible under All Words) but lose this specific tag.
    private static let deckSlugDrop: Set<String> = ["time_numbers"]

    static func seedIfNeeded(_ context: ModelContext) {
        let descriptor = FetchDescriptor<VocabularyWord>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        let defaults = UserDefaults.standard
        guard existingCount == 0 else {
            // Existing data: backfill seededLanguage if missing so the
            // onboarding swap logic knows what's currently loaded (matters
            // for users upgrading from a build that predates this key).
            if defaults.string(forKey: OnboardingDefaultsKey.seededLanguage) == nil {
                let assumed = OnboardingStore.targetLanguage ?? .spanish
                defaults.set(assumed.rawValue, forKey: OnboardingDefaultsKey.seededLanguage)
            }
            backfillChatSessionLanguageIfNeeded(context: context, defaults: defaults)
            let storedVersion = defaults.integer(forKey: OnboardingDefaultsKey.deckTaxonomyVersion)
            if storedVersion < currentDeckTaxonomyVersion {
                migrateDeckTaxonomy(context: context)
                defaults.set(currentDeckTaxonomyVersion, forKey: OnboardingDefaultsKey.deckTaxonomyVersion)
            }
            return
        }

        let language = OnboardingStore.targetLanguage ?? .spanish
        seedLanguage(language, context: context)
    }

    /// Insert the bundled decks + words for `language`. Assumes the previous
    /// language's *seeded* rows have already been cleared; user-added custom
    /// words may remain (they're language-scoped at query time). Bypasses the
    /// `seedIfNeeded` empty-DB guard so it works even when custom words from
    /// other languages are still present.
    private static func seedLanguage(_ language: TargetLanguage, context: ModelContext) {
        guard let seed = loadSeed(for: language) else { return }
        let encoder = JSONEncoder()
        for deck in seed.decks ?? [] {
            context.insert(makeDeck(deck))
        }
        for word in seed.words {
            context.insert(makeWord(word, encoder: encoder))
        }
        try? context.save()
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: OnboardingDefaultsKey.seededLanguage)
        defaults.set(currentDeckTaxonomyVersion, forKey: OnboardingDefaultsKey.deckTaxonomyVersion)
    }

    /// Refresh existing installs against the current bundled deck taxonomy:
    /// replace all Deck records with the new list from the JSON seed, and
    /// rewrite each word's `deckSlugsJSON` through `deckSlugRemap`/`deckSlugDrop`.
    /// Preserves words, learning progress, and review history.
    private static func migrateDeckTaxonomy(context: ModelContext) {
        do {
            try context.delete(model: Deck.self)
        } catch {
            print("SeedDataLoader.migrateDeckTaxonomy: failed to delete decks — \(error)")
        }
        if let seed = loadSeed() {
            for deck in seed.decks ?? [] {
                context.insert(makeDeck(deck))
            }
        }

        let wordDescriptor = FetchDescriptor<VocabularyWord>()
        if let words = try? context.fetch(wordDescriptor) {
            for word in words {
                let old = word.deckSlugs
                var new: [String] = []
                for slug in old {
                    if deckSlugDrop.contains(slug) { continue }
                    let mapped = deckSlugRemap[slug] ?? slug
                    if !new.contains(mapped) { new.append(mapped) }
                }
                if new != old {
                    word.setDeckSlugs(new)
                }
            }
        }

        // If the user's currently-selected deck no longer exists in the new
        // taxonomy, snap them back to All Words to avoid a filter that hides
        // every card.
        let defaults = UserDefaults.standard
        let selectedSlug = defaults.string(forKey: DeckConstants.selectedDeckDefaultsKey) ?? DeckConstants.allSlug
        if selectedSlug != DeckConstants.allSlug,
           deckSlugDrop.contains(selectedSlug) || deckSlugRemap[selectedSlug] != nil {
            let resolved = deckSlugRemap[selectedSlug] ?? DeckConstants.allSlug
            defaults.set(resolved, forKey: DeckConstants.selectedDeckDefaultsKey)
        }

        try? context.save()
    }

    /// Stamp existing `ChatSession` rows with the current target language,
    /// once. Pre-feature builds wiped all sessions on a language switch, so
    /// every surviving row belongs to whatever language is active at upgrade.
    private static func backfillChatSessionLanguageIfNeeded(context: ModelContext, defaults: UserDefaults) {
        guard !defaults.bool(forKey: OnboardingDefaultsKey.chatSessionLanguageBackfilled) else { return }
        let current = OnboardingStore.targetLanguage ?? .spanish
        if let sessions = try? context.fetch(FetchDescriptor<ChatSession>()) {
            for session in sessions {
                session.languageRaw = current.rawValue
            }
            try? context.save()
        }
        defaults.set(true, forKey: OnboardingDefaultsKey.chatSessionLanguageBackfilled)
    }

    /// Swap the user's target language. Wipes the previous language's *seeded*
    /// vocabulary and decks, then reseeds from the new language's bundled JSON.
    /// Resets the deck and level filters so the new catalogue isn't hidden by
    /// a slug that doesn't exist in it.
    ///
    /// User-added custom words (id `custom-…`) are deliberately KEPT — they're
    /// the user's own content and would otherwise be lost permanently on a
    /// language round-trip. They carry their language in their id and every
    /// word query scopes by language, so a German custom word stays hidden
    /// while Spanish is active and reappears on switching back.
    ///
    /// `LearningProgress`, `ReviewLog`, `ChatSession`, and `ChatMessage` are
    /// likewise preserved. Progress' `wordID` values are language-prefixed so
    /// they harmlessly orphan while another language is active and rebind when
    /// the user switches back.
    static func switchLanguage(to language: TargetLanguage, context: ModelContext) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: OnboardingDefaultsKey.targetLanguage)

        do {
            // Delete only seeded words; keep the user's custom words.
            let existing = try context.fetch(FetchDescriptor<VocabularyWord>())
            for word in existing where !word.id.hasPrefix("custom-") {
                context.delete(word)
            }
            try context.delete(model: Deck.self)
            try context.save()
        } catch {
            print("SeedDataLoader.switchLanguage: failed to clear data — \(error)")
        }

        defaults.set(DeckConstants.allSlug, forKey: DeckConstants.selectedDeckDefaultsKey)
        defaults.removeObject(forKey: OnboardingDefaultsKey.seededLanguage)

        // Seed directly (not via seedIfNeeded): surviving custom words mean the
        // DB isn't empty, so the seedIfNeeded guard would skip the new seed.
        seedLanguage(language, context: context)
        DailyWordService.refresh(context: context)
    }

    /// Load the seed for the user's currently selected target language.
    /// Falls back to Spanish if no language has been chosen yet (e.g. the
    /// very first launch before onboarding completes).
    static func loadSeed() -> SeedFile? {
        loadSeed(for: OnboardingStore.targetLanguage ?? .spanish)
    }

    static func loadSeed(for language: TargetLanguage) -> SeedFile? {
        let resourceName = language.seedResourceName
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            print("SeedDataLoader: \(resourceName).json not found in bundle")
            // Last-resort fallback to Spanish so the app still works on
            // first launch even if a non-Spanish language is picked before
            // its dataset is bundled.
            if language != .spanish,
               let fallbackURL = Bundle.main.url(forResource: TargetLanguage.spanish.seedResourceName, withExtension: "json") {
                print("SeedDataLoader: falling back to Spanish seed")
                return decode(url: fallbackURL)
            }
            return nil
        }
        return decode(url: url)
    }

    private static func decode(url: URL) -> SeedFile? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SeedFile.self, from: data)
        } catch {
            print("SeedDataLoader error: \(error)")
            return nil
        }
    }

    static func makeDeck(_ deck: SeedDeck) -> Deck {
        Deck(
            slug: deck.slug,
            displayName: deck.displayName,
            deckDescription: deck.description ?? "",
            iconSystemName: deck.icon ?? "square.stack",
            sortOrder: deck.sortOrder ?? 0
        )
    }

    static func makeWord(_ word: SeedWord, encoder: JSONEncoder) -> VocabularyWord {
        let definitionsJSON = (try? encoder.encode(word.definitions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let translationsJSON = (try? encoder.encode(word.example.translations))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let deckSlugsJSON = (try? encoder.encode(word.decks ?? [DeckConstants.commonSlug]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return VocabularyWord(
            id: word.id,
            rank: word.rank,
            lemma: word.lemma,
            partOfSpeech: word.partOfSpeech,
            definitionsJSON: definitionsJSON,
            exampleSentence: word.example.text,
            exampleTranslationsJSON: translationsJSON,
            deckSlugsJSON: deckSlugsJSON,
            cefrLevel: word.cefrLevel
        )
    }
}
