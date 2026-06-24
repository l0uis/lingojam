import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Looks up a word the user encountered outside the app and fills in the
/// pieces the vocabulary list needs: the dictionary lemma, part of speech,
/// a definition in the user's language, and a short example sentence in the
/// target language with its translation.
///
/// Resolves vocabulary entries through the cloud proxy (Claude, server-side)
/// so they're accurate. An on-device Apple Foundation Models path also exists
/// but is OFF by default (`FeatureFlags.useOnDeviceEnrichmentFallback`): the
/// small model hallucinates vocabulary, which defeats the point. When the
/// cloud is unreachable we return nil rather than guess, and the Add Word
/// sheet shows its "couldn't look this up" banner for manual entry.
///
/// The on-device path runs in two anchored steps rather than one combined
/// call. The small model, asked to do everything at once, drifts — it will
/// happily invent a word for the example sentence that has nothing to do
/// with the input (e.g. "geläufig" → a sentence about a made-up
/// "Geläublichkeit"). Resolving the lemma first and then generating the
/// example with that exact lemma injected as literal text keeps it anchored,
/// and a containment check blanks any example that still drifts.
@MainActor
final class WordEnrichmentService {
    static let shared = WordEnrichmentService()

    private init() {}

    struct Enrichment {
        var lemma: String
        var partOfSpeech: String
        var definition: String
        var exampleSentence: String
        var exampleTranslation: String
    }

    /// Generates vocabulary details for `raw`, assumed to be a word or short
    /// phrase in `targetLanguage`. `nativeLanguageCode` is the ISO code the
    /// definition and example translation should be written in (the same key
    /// `LocaleService` reads back). Returns nil if no path can resolve the
    /// word; a missing example alone is tolerated (returned blank) so the
    /// user can still save and add one by hand.
    func enrich(
        word raw: String,
        targetLanguage: TargetLanguage,
        nativeLanguageCode: String
    ) async -> Enrichment? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let target = targetLanguage.englishName
        let nativeName = Locale.current
            .localizedString(forLanguageCode: nativeLanguageCode) ?? "English"

        // 1. Cloud (Claude) — accurate, no hallucinated vocabulary. Preferred.
        if FeatureFlags.useCloudEnrichment,
           let cloud = await enrichViaProxy(
               trimmed, target: target, nativeName: nativeName
           ) {
            return cloud
        }

        // 2. On-device Apple model — opt-in only. Off by default because the
        // small model hallucinates vocabulary; we'd rather return nil and let
        // the sheet show its "couldn't look this up" banner than display a
        // made-up word. See FeatureFlags.useOnDeviceEnrichmentFallback.
        if FeatureFlags.useOnDeviceEnrichmentFallback {
            return await enrichOnDevice(trimmed, target: target, nativeName: nativeName)
        }
        return nil
    }

    private func enrichViaProxy(
        _ input: String,
        target: String,
        nativeName: String
    ) async -> Enrichment? {
        do {
            let entry = try await WalrusEnrichmentClient.shared.enrich(
                word: input,
                targetLanguageName: target,
                nativeLanguageName: nativeName
            )
            let lemma = Self.clean(entry.lemma)
            guard !lemma.isEmpty else { return nil }
            // Trust but verify: even with Claude, blank an example that
            // somehow doesn't contain the word rather than show a wrong one.
            let sentence = Self.clean(entry.exampleSentence)
            let exampleOK = !sentence.isEmpty && Self.sentence(sentence, contains: lemma)
            return Enrichment(
                lemma: lemma,
                partOfSpeech: Self.clean(entry.partOfSpeech).lowercased(),
                definition: Self.clean(entry.definition),
                exampleSentence: exampleOK ? sentence : "",
                exampleTranslation: exampleOK ? Self.clean(entry.exampleTranslation) : ""
            )
        } catch {
            #if DEBUG
            print("WordEnrichmentService proxy failed: \(error)")
            #endif
            return nil
        }
    }

    private func enrichOnDevice(
        _ input: String,
        target: String,
        nativeName: String
    ) async -> Enrichment? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            guard let base = await lookUp(input, target: target, nativeName: nativeName) else {
                return nil
            }
            let example = await makeExample(
                lemma: base.lemma,
                target: target,
                nativeName: nativeName
            )
            return Enrichment(
                lemma: base.lemma,
                partOfSpeech: base.partOfSpeech,
                definition: base.definition,
                exampleSentence: example?.sentence ?? "",
                exampleTranslation: example?.translation ?? ""
            )
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func lookUp(
        _ input: String,
        target: String,
        nativeName: String
    ) async -> (lemma: String, partOfSpeech: String, definition: String)? {
        let instructions = """
        You are a bilingual dictionary inside a language-learning app. The user \
        gives you a single word or short phrase in \(target). Identify it.

        Rules:
        - `lemma`: the standard dictionary spelling of the SAME word the user \
          typed. Preserve the word — only fix diacritics, accents, or casing, \
          and reduce an inflected form to its base form. Never substitute a \
          different word and never invent one.
        - `partOfSpeech`: one lowercase English word — noun, verb, adjective, \
          adverb, pronoun, preposition, conjunction, or interjection.
        - `definition`: a short translation gloss in \(nativeName), like a \
          flashcard — a few words, not a sentence. Use the infinitive for \
          verbs ("to arrive"). e.g. "to arrive"; "common, familiar".
        - If the input is not clearly \(target), do your best with the closest \
          real word. Never refuse.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: Prompt(input),
                generating: WordLookupOutput.self
            )
            let lemma = Self.clean(response.content.lemma)
            guard !lemma.isEmpty else { return nil }
            return (
                lemma,
                Self.clean(response.content.partOfSpeech).lowercased(),
                Self.clean(response.content.definition)
            )
        } catch {
            #if DEBUG
            print("WordEnrichmentService.lookUp failed: \(error)")
            #endif
            return nil
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func makeExample(
        lemma: String,
        target: String,
        nativeName: String
    ) async -> (sentence: String, translation: String)? {
        let instructions = """
        You write example sentences for a \(target) learner. You will be given \
        one \(target) word. Write a single short, natural sentence that uses \
        that exact word (you may inflect it for grammar, but do not replace it). \
        Use ONLY real, standard \(target) words — never invent or misspell \
        words. Then translate your sentence into \(nativeName).

        - `sentence`: the \(target) sentence containing the word.
        - `translation`: the same sentence in \(nativeName).
        """
        // One retry: the small model occasionally drifts and writes a sentence
        // that doesn't contain the word. We'd rather show no example than a
        // wrong one, so we verify containment and blank it on a second miss.
        for _ in 0..<2 {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: Prompt(lemma),
                    generating: ExampleOutput.self
                )
                let sentence = Self.clean(response.content.sentence)
                let translation = Self.clean(response.content.translation)
                if !sentence.isEmpty, Self.sentence(sentence, contains: lemma) {
                    return (sentence, translation)
                }
            } catch {
                #if DEBUG
                print("WordEnrichmentService.makeExample failed: \(error)")
                #endif
                return nil
            }
        }
        return nil
    }
    #endif

    /// Loose containment check tolerant of inflection: does `sentence` include
    /// the word's stem? We fold diacritics and casing, then look for the lemma
    /// minus its final couple of characters (so "geläufig" matches "geläufige"
    /// but a fabricated word fails). Short lemmas are matched whole.
    static func sentence(_ sentence: String, contains lemma: String) -> Bool {
        let haystack = fold(sentence)
        let needle = fold(lemma)
        guard !needle.isEmpty else { return false }
        let stemLength = max(4, needle.count - 2)
        let stem = String(needle.prefix(stemLength))
        return haystack.contains(stem)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct WordLookupOutput {
    @Guide(description: "The standard dictionary spelling of the same word the user typed, in its base form. Never a different or invented word.")
    var lemma: String
    @Guide(description: "Part of speech as one lowercase English word: noun, verb, adjective, adverb, pronoun, preposition, conjunction, or interjection.")
    var partOfSpeech: String
    @Guide(description: "A concise definition written in the user's native language.")
    var definition: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ExampleOutput {
    @Guide(description: "One short, natural sentence in the target language that uses the given word. Only real, correctly spelled words.")
    var sentence: String
    @Guide(description: "The sentence translated into the user's native language.")
    var translation: String
}
#endif
