import Foundation

/// Scripted, no-network walrus. Drives the chat UX while we figure out the
/// LLM integration. Picks target words from a candidate list (chosen by the
/// caller from the user's `LearningProgress`), weaves each one into a
/// prompt drawn from the level's template JSON, and detects whether the
/// user's reply used the word in some inflected form.
struct MockWalrusBrain: WalrusBrain {
    /// Number of walrus prompt turns before the closer. Total walrus turns
    /// = 1 opener + `promptTurnCount` prompts + 1 closer.
    static let promptTurnCount = 5

    /// Minimum target words used for the user to pass the call.
    static let passingThreshold = 3

    func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
        let templates = Self.loadTemplates(for: level)
        let raw = templates.openers.randomElement() ?? Self.fallbackOpener
        // Substitute {WORD} (and {WORDS}) with the freshest target word
        // so Walter audibly references what the user just studied.
        // `targetWords` is sorted recent-first by `pickTargetWords`, so
        // `.first` is the most recently swiped lemma.
        let freshest = targetWords.first?.lemma ?? ""
        let conjunction = (OnboardingStore.targetLanguage ?? .spanish).listConjunction
        let opener = raw
            .replacingOccurrences(of: "{WORD}", with: freshest)
            .replacingOccurrences(
                of: "{WORDS}",
                with: targetWords.prefix(2).map(\.lemma).joined(separator: " \(conjunction) ")
            )
        return WalrusTurn(text: opener, endsConversation: false)
    }

    func reply(
        history: [ChatTurn],
        level: CEFRLevel,
        targetWords: [VocabularyWord]
    ) async -> WalrusTurn {
        let templates = Self.loadTemplates(for: level)

        // Walter has spoken once for the opener, then one prompt per user
        // reply. `walrusTurnCount` after this reply will be:
        //   1 (opener) + N walrus prompts already in history + 1 (this one).
        let walrusSoFar = history.filter { $0.role == .walrus }.count
        let promptIndex = walrusSoFar - 1 // -1 because opener was index 0

        if promptIndex >= Self.promptTurnCount {
            let closer = templates.closers.randomElement() ?? Self.fallbackCloser
            return WalrusTurn(text: closer, endsConversation: true)
        }

        // Pick the target word for this turn. Cycle through `targetWords`
        // so each one gets at least one prompt.
        let targetIndex = max(0, promptIndex) % max(1, targetWords.count)
        let word = targetWords.indices.contains(targetIndex) ? targetWords[targetIndex] : nil

        let prompt: String
        if let word, let template = templates.prompts.randomElement() {
            prompt = template.replacingOccurrences(of: "{WORD}", with: word.lemma)
        } else {
            prompt = templates.fillers.randomElement() ?? Self.fallbackFiller
        }

        // Occasional filler before the prompt to feel less robotic.
        let lead = (promptIndex > 0 && Bool.random())
            ? (templates.fillers.randomElement().map { $0 + " " } ?? "")
            : ""

        // No correction: a template brain has no way to judge the learner's
        // grammar, and guessing would be worse than staying quiet.
        return WalrusTurn(text: lead + prompt, endsConversation: false)
    }

    func wrapUp(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        history: [ChatTurn]
    ) async -> WalrusTurn {
        // Use the closer from the level's template — but prefixed with a
        // small acknowledgement that the user nailed all the words. Both
        // pieces are pulled per target language: closer from the language-
        // suffixed template JSON, acknowledgement from `WalterCopy`.
        let templates = Self.loadTemplates(for: level)
        let copy = WalterCopy.forLanguage(OnboardingStore.targetLanguage ?? .spanish)
        let closer = templates.closers.randomElement() ?? Self.fallbackCloser
        let acknowledgement = copy.wrapUpAcknowledgements.randomElement()
            ?? copy.wrapUpAcknowledgements.first
            ?? "Las has usado todas."
        return WalrusTurn(text: "\(acknowledgement) \(closer)", endsConversation: true)
    }

    func evaluate(
        transcript: [ChatTurn],
        targetWords: [VocabularyWord],
        level: CEFRLevel
    ) async -> ChatEvaluation {
        let userText = transcript
            .filter { $0.role == .user }
            .map { $0.text }
            .joined(separator: " ")

        var hits: [String] = []
        for word in targetWords {
            if LemmaMatcher.userText(userText, mentions: word.lemma, partOfSpeech: word.partOfSpeech) {
                hits.append(word.id)
            }
        }
        let passed = hits.count >= Self.passingThreshold
        let encouragement = passed
            ? String(localized: "Nice work — you used \(hits.count) of the words you've been studying.")
            : String(localized: "Good chat. Next time, try to weave in more of the vocabulary you've learned.")
        return ChatEvaluation(
            elicitedWordIDs: hits,
            passed: passed,
            encouragement: encouragement
        )
    }

    // MARK: - Template loading

    private struct TemplateBundle: Decodable {
        let level: String
        let openers: [String]
        let prompts: [String]
        let fillers: [String]
        let closers: [String]
    }

    /// Used only if no template file is found at all. Spanish-flavoured
    /// since Spanish is the default fallback language.
    private static let fallbackOpener = "¡Hola!"
    private static let fallbackCloser = "Hasta luego."
    private static let fallbackFiller = "Cuéntame más."

    private static func loadTemplates(for level: CEFRLevel) -> TemplateBundle {
        let language = OnboardingStore.targetLanguage ?? .spanish
        let levelSuffix = level.rawValue.lowercased()
        // Spanish keeps its original filenames (no language suffix) for
        // back-compat with installs that predate multi-language support.
        // Other languages use the `walrus_templates_{code}_{level}` pattern.
        let candidates: [String]
        if language == .spanish {
            candidates = ["walrus_templates_\(levelSuffix)"]
        } else {
            candidates = [
                "walrus_templates_\(language.languageCode)_\(levelSuffix)",
                "walrus_templates_\(levelSuffix)", // last-resort Spanish fallback
            ]
        }
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let bundle = try? JSONDecoder().decode(TemplateBundle.self, from: data) {
                return bundle
            }
        }
        return TemplateBundle(
            level: level.rawValue,
            openers: [fallbackOpener],
            prompts: ["Cuéntame más."],
            fillers: ["Entiendo."],
            closers: [fallbackCloser]
        )
    }
}

private extension TargetLanguage {
    /// Localised "and" used to join two lemmas in an opener: "X and Y".
    var listConjunction: String {
        switch self {
        case .spanish: "y"
        case .french: "et"
        case .italian: "e"
        case .german: "und"
        }
    }
}

// MARK: - Lemma matcher

/// Lightweight matcher: tests whether `userText` mentions `lemma` in any
/// common inflected form across the four supported languages. Not perfect
/// — strong/irregular verbs and German separable prefixes will slip
/// through — but good enough for MVP word-recall detection on the
/// hand-curated frequency list. The LLM evaluator judges semantically.
enum LemmaMatcher {
    static func userText(_ text: String, mentions lemma: String, partOfSpeech: String) -> Bool {
        let language = OnboardingStore.targetLanguage ?? .spanish
        let normText = normalize(text)
        let normLemma = normalize(lemma)
        guard !normLemma.isEmpty else { return false }

        // Direct substring check on the normalized lemma — catches lemma
        // itself and any inflection whose root contains the lemma.
        if containsWord(normText, normLemma) { return true }

        let pos = partOfSpeech.lowercased()
        let isVerb = pos.contains("verb") && !pos.contains("adverb")
        if isVerb {
            for stem in verbStems(from: normLemma, language: language) where !stem.isEmpty {
                if containsWord(normText, stem, prefixOnly: true) { return true }
            }
        }

        for variant in nominalVariants(of: normLemma, language: language) {
            if containsWord(normText, variant) { return true }
        }

        return false
    }

    /// Lowercase + strip diacritics. The folding handles every diacritic
    /// across ES/FR/IT/DE: ñ→n, ç→c, ü→u, é/è/ê→e, ß stays as "ss" via
    /// lowercase normalisation in modern Swift.
    static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
            .lowercased()
    }

    private static func containsWord(_ text: String, _ needle: String, prefixOnly: Bool = false) -> Bool {
        guard !needle.isEmpty else { return false }
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = text.unicodeScalars.split(whereSeparator: { separators.contains($0) }).map(String.init)
        if prefixOnly {
            return tokens.contains { $0.hasPrefix(needle) && $0.count >= needle.count }
        }
        return tokens.contains(needle)
    }

    private static func verbStems(from lemma: String, language: TargetLanguage) -> [String] {
        let endings: [String]
        switch language {
        case .spanish: endings = ["ar", "er", "ir"]
        case .french: endings = ["er", "ir", "re", "oir"]
        case .italian: endings = ["are", "ere", "ire", "rsi"]
        case .german: endings = ["en", "ern", "eln"]
        }
        for ending in endings where lemma.hasSuffix(ending) {
            let stem = String(lemma.dropLast(ending.count))
            if stem.count >= 2 { return [stem] }
        }
        return []
    }

    private static func nominalVariants(of lemma: String, language: TargetLanguage) -> [String] {
        var out: [String] = []
        switch language {
        case .spanish:
            if lemma.last.map({ "aeiouáéíóú".contains($0) }) ?? false {
                out.append(lemma + "s")
            } else {
                out.append(lemma + "es")
            }
            if lemma.hasSuffix("o") { out.append(String(lemma.dropLast()) + "a") }
            if lemma.hasSuffix("a") { out.append(String(lemma.dropLast()) + "o") }
        case .french:
            // Most plurals just add -s (silent in speech, written).
            if !lemma.hasSuffix("s") && !lemma.hasSuffix("x") && !lemma.hasSuffix("z") {
                out.append(lemma + "s")
            }
            // Feminine adjectives often add -e.
            out.append(lemma + "e")
        case .italian:
            // -o → -i, -a → -e, -e → -i (covers most regular nouns/adjectives).
            if lemma.hasSuffix("o") { out.append(String(lemma.dropLast()) + "i") }
            else if lemma.hasSuffix("a") { out.append(String(lemma.dropLast()) + "e") }
            else if lemma.hasSuffix("e") { out.append(String(lemma.dropLast()) + "i") }
        case .german:
            // German plurals are highly irregular; cover the common
            // suffixes and rely on the prefix-stem check for inflections.
            out.append(lemma + "e")
            out.append(lemma + "en")
            out.append(lemma + "er")
            out.append(lemma + "s")
        }
        return out
    }
}

// MARK: - Back-compat shim

/// Old name kept so any test or call site that references the Spanish-only
/// matcher still compiles. New code should use `LemmaMatcher`.
enum SpanishLemmaMatcher {
    static func userText(_ text: String, mentions lemma: String, partOfSpeech: String) -> Bool {
        LemmaMatcher.userText(text, mentions: lemma, partOfSpeech: partOfSpeech)
    }

    static func normalize(_ s: String) -> String {
        LemmaMatcher.normalize(s)
    }
}
