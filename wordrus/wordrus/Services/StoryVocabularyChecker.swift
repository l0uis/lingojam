import Foundation
import NaturalLanguage

/// A lemma the learner knows (or is about to learn), with its seed part of
/// speech when available. POS tells the checker which lemmas are verbs; without
/// it, verbs are inferred from their infinitive ending.
nonisolated struct StoryWord: Hashable, Sendable, ExpressibleByStringLiteral {
    let lemma: String
    let partOfSpeech: String?

    init(lemma: String, partOfSpeech: String? = nil) {
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
    }

    init(stringLiteral value: String) {
        self.init(lemma: value)
    }
}

/// On-device check that a generated story stays inside the learner's
/// vocabulary. Brains (Claude, Apple, Mock) only generate; this decides
/// whether the result is usable.
///
/// Every word token gets a *set* of candidate lemmas — its surface form,
/// NLTagger's lemma, lexicon aliases of both, and (when nothing matches yet)
/// morphology fallbacks — and is known if any candidate is in the allowed set.
/// Candidates are deliberately generous: a false "unknown" costs a repair round
/// trip, a false "known" costs one slightly-too-hard word.
///
/// Skipped entirely (not counted for coverage): punctuation, numbers, names and
/// function words. German separable verbs are rejoined ("steht … auf" →
/// aufstehen), compounds are split (Bahnhofsuhr → Bahnhof + Uhr), French and
/// Italian elisions are split (dell'isola → dell' + isola), and Spanish and
/// Italian clitics are stripped (comprándolo → comprando → comprar).
///
/// NLTagger's lemma model is optional. The iOS simulator has none for Spanish
/// and Italian assets may be missing on device, so known verbs are also matched
/// by stem + ending (compró → compr|ó → comprar, quiero → quier|o → querer),
/// with irregular forms coming from the lexicon aliases.
///
/// Comparison is case-insensitive everywhere. Spanish, French and Italian also
/// ignore accents (except ñ); German folds umlauts to their transliteration
/// (können ≡ koennen) because NLTagger itself returns transliterated lemmas
/// for some German verbs.
nonisolated struct StoryVocabularyChecker {
    struct Policy: Equatable, Sendable {
        var minimumCoverage: Double = 0.97
        var maximumUnknownLemmas: Int = 2
        var minimumNewWordUses: Int = 2
        var wordCount: ClosedRange<Int>
    }

    /// Characters who may appear in any story without being vocabulary.
    /// The walrus is "Dr Tusk" in the app and "Walter" in code.
    static let defaultNames: Set<String> = ["Dr", "Tusk", "Walter"]

    /// German words that open a new clause without punctuation, so a particle
    /// before them is clause-final ("Er kauft ein und geht.").
    private static let germanClauseOpeners: Set<String> = [
        "und", "oder", "aber", "denn", "sondern", "weil", "dass", "wenn", "als", "ob", "obwohl",
    ]

    let lexicon: StoryLexicon
    let policy: Policy

    private let languageCode: String
    private let usesTaggerLemmas: Bool
    private let functionKeys: Set<String>
    private let allowedKeys: Set<String>
    private let newWords: [(lemma: String, keys: Set<String>, phrase: [String])]
    private let nameKeys: Set<String>
    private let aliasKeys: [String: [String]]
    private let inflectionSuffixes: [(from: String, to: String)]
    private let cliticSuffixes: [String]
    private let separablePrefixes: Set<String>
    private let compoundLinkers: [String]
    private let verbStems: [String: [VerbEntry]]
    /// Allowed verbs built on an irregular base: obtener = ob + tener, so
    /// "obtuvo" = ob + "tuvo" (an alias of tener). Also apprendre, ottenere,
    /// versprechen (inseparable participles drop ge-: ver + "sprochen").
    private let prefixedIrregulars: [(prefix: String, base: String, verb: String)]

    private struct VerbEntry {
        let lemmaKey: String
        let endings: Set<String>
        /// German separable verbs are also indexed under their base verb, but
        /// only match when this particle is present (aufstehen ← auf + steh|t).
        let requiredPrefix: String?
    }

    /// - Parameter usesTaggerLemmas: `false` ignores NLTagger's lemma model,
    ///   as on a device without lemma assets. Tests use it to pin the fallback.
    init(
        lexicon: StoryLexicon,
        known: some Sequence<StoryWord>,
        new: [StoryWord],
        names: Set<String> = StoryVocabularyChecker.defaultNames,
        policy: Policy,
        usesTaggerLemmas: Bool = true
    ) {
        let code = lexicon.language
        let fold = { (s: String) in StoryVocabularyChecker.fold(s, languageCode: code) }
        self.lexicon = lexicon
        self.policy = policy
        self.languageCode = code
        self.usesTaggerLemmas = usesTaggerLemmas
        let functionKeys = Set(lexicon.functionWords.map(fold))
        self.functionKeys = functionKeys

        var aliasKeys: [String: [String]] = [:]
        for (form, targets) in lexicon.aliases {
            aliasKeys[fold(form), default: []] += targets.map(fold)
        }
        self.aliasKeys = aliasKeys

        let known = Array(known)
        var allowed = Set<String>()
        for word in known {
            allowed.formUnion(Self.variantKeys(of: word.lemma, languageCode: code, functionKeys: functionKeys))
        }
        self.newWords = new.map { word in
            let keys = Self.variantKeys(of: word.lemma, languageCode: code, functionKeys: functionKeys)
            let parts = Self.phraseParts(of: word.lemma)
            return (word.lemma, keys, parts.count > 1 ? parts.map(fold) : [])
        }
        for word in newWords { allowed.formUnion(word.keys) }
        self.allowedKeys = allowed
        self.nameKeys = Set(names.map(fold))
        self.inflectionSuffixes = lexicon.inflectionSuffixes.compactMap { pair in
            pair.count == 2 ? (fold(pair[0]), fold(pair[1])) : nil
        }
        self.cliticSuffixes = (lexicon.cliticSuffixes ?? []).map(fold).sorted { $0.count > $1.count }
        let separablePrefixes = Set((lexicon.separablePrefixes ?? []).map(fold))
        self.separablePrefixes = separablePrefixes
        self.compoundLinkers = (lexicon.compoundLinkers ?? []).map(fold).sorted { $0.count > $1.count }
        self.verbStems = Self.buildVerbIndex(
            words: known + new, lexicon: lexicon, separablePrefixes: separablePrefixes
        )
        let irregularBases = Set(aliasKeys.values.joined()).filter { $0.count >= 3 }
        var prefixed: [(prefix: String, base: String, verb: String)] = []
        // Only verbs can be built on an irregular verb — scanning just the
        // indexed verbs keeps this cheap with a whole vocabulary allowed.
        let verbKeys = Set(verbStems.values.joined().map(\.lemmaKey))
        for verb in verbKeys {
            for base in irregularBases where verb.count > base.count && verb.hasSuffix(base) {
                prefixed.append((String(verb.dropLast(base.count)), base, verb))
            }
        }
        self.prefixedIrregulars = prefixed
    }

    // MARK: - Check

    /// `questions` is every question and answer option, flattened. They count
    /// toward coverage and unknown lemmas but not toward length or new-word use.
    func check(story: String, questions: [String] = []) -> StoryCoverageReport {
        let tagger = Tagger(languageCode: languageCode, usesLemmas: usesTaggerLemmas)
        let storyTokens = tokenize(story, tagger: tagger)
        let questionTokens = questions.flatMap { tokenize($0, tagger: tagger) }

        var contentCount = 0
        var unknownCount = 0
        var unknownByKey: [String: String] = [:]
        var unknownOrder: [String] = []
        var newUses = Dictionary(uniqueKeysWithValues: newWords.map { ($0.lemma, 0) })
        var storyKeySequence: [Set<String>] = []

        for (index, token) in (storyTokens + questionTokens).enumerated() {
            let isStory = index < storyTokens.count
            let analysis = analyze(token, tagger: tagger)
            if isStory {
                storyKeySequence.append(analysis.keys)
                for word in newWords where word.phrase.isEmpty && !analysis.keys.isDisjoint(with: word.keys) {
                    newUses[word.lemma, default: 0] += 1
                }
            }
            switch analysis.kind {
            case .number, .name, .function:
                continue
            case .known:
                contentCount += 1
            case .unknown(let display):
                contentCount += 1
                unknownCount += 1
                let key = fold(display)
                if unknownByKey[key] == nil {
                    unknownByKey[key] = display
                    unknownOrder.append(key)
                }
            }
        }

        // Multiword new words ("tal vez") count as consecutive token matches.
        for word in newWords where !word.phrase.isEmpty {
            var uses = 0
            var i = 0
            while i + word.phrase.count <= storyKeySequence.count {
                let matches = word.phrase.indices.allSatisfy { storyKeySequence[i + $0].contains(word.phrase[$0]) }
                if matches { uses += 1; i += word.phrase.count } else { i += 1 }
            }
            newUses[word.lemma] = uses
        }

        let wordCount = storyTokens.filter { !$0.surface.hasSuffix("'") }.count
        let coverage = contentCount == 0 ? 1 : Double(contentCount - unknownCount) / Double(contentCount)
        let unknownLemmas = unknownOrder.compactMap { unknownByKey[$0] }

        var failures: [StoryCoverageReport.Failure] = []
        if coverage < policy.minimumCoverage { failures.append(.lowCoverage) }
        if unknownLemmas.count > policy.maximumUnknownLemmas { failures.append(.tooManyUnknownLemmas) }
        let underused = newWords.map(\.lemma).filter { (newUses[$0] ?? 0) < policy.minimumNewWordUses }
        if !underused.isEmpty { failures.append(.newWordsUnderused(underused)) }
        if wordCount < policy.wordCount.lowerBound { failures.append(.tooShort) }
        if wordCount > policy.wordCount.upperBound { failures.append(.tooLong) }

        return StoryCoverageReport(
            coverage: coverage,
            contentTokenCount: contentCount,
            unknownTokenCount: unknownCount,
            unknownLemmas: unknownLemmas,
            newWordUses: newUses,
            wordCount: wordCount,
            failures: failures
        )
    }

    // MARK: - Annotation

    /// One word of a text as the checker sees it — what the story screen uses
    /// for tap targets and new-word highlighting.
    struct AnnotatedToken: Equatable {
        enum Role: Equatable { case number, name, function, known, unknown }

        /// Range in the annotated text.
        let range: Range<String.Index>
        let surface: String
        let role: Role
        /// Folded lemma candidates, for looking the word up.
        let keys: Set<String>
        /// The lemma NLTagger (or separable-verb joining) settled on, if any.
        let lemma: String?
        /// The new word this token is a form of (single-word new words only).
        let newWord: String?

        /// Keys in lookup order: the settled lemma, the surface, then the rest.
        func lookupKeys(languageCode: String) -> [String] {
            let preferred = [lemma, surface].compactMap { $0 }.map { StoryVocabularyChecker.fold($0, languageCode: languageCode) }
            return preferred + keys.subtracting(preferred).sorted()
        }
    }

    func annotate(_ text: String) -> [AnnotatedToken] {
        let tagger = Tagger(languageCode: languageCode, usesLemmas: usesTaggerLemmas)
        return tokenize(text, tagger: tagger).map { token in
            let analysis = analyze(token, tagger: tagger)
            let role: AnnotatedToken.Role = switch analysis.kind {
            case .number: .number
            case .name: .name
            case .function: .function
            case .known: .known
            case .unknown: .unknown
            }
            let newWord = newWords.first { $0.phrase.isEmpty && !analysis.keys.isDisjoint(with: $0.keys) }?.lemma
            return AnnotatedToken(
                range: token.range,
                surface: token.surface,
                role: role,
                keys: analysis.keys,
                lemma: token.separableLemma ?? token.lemma,
                newWord: newWord
            )
        }
    }

    // MARK: - Tokens

    private struct Token {
        /// In the text passed to `check`/`annotate` (not the apostrophe-
        /// normalised copy NLTagger sees), trimmed to `surface`.
        let range: Range<String.Index>
        let surface: String
        let lemma: String?
        let lexicalClass: NLTag?
        let isTaggedName: Bool
        let isSentenceInitial: Bool
        let clause: Int
        /// German separable verb rejoined with its particle ("aufstehen").
        var separableLemma: String?
        /// German separable particle already credited to its verb.
        var isConsumedParticle = false
    }

    private func tokenize(_ rawText: String, tagger: Tagger) -> [Token] {
        let text = rawText.replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty else { return [] }
        // ’ → ' keeps the Character count, so ranges map back by offset.
        let rawIndices = Array(rawText.indices) + [rawText.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: (Array(text.indices) + [text.endIndex]).enumerated().map { ($1, $0) })
        func rawRange(_ range: Range<String.Index>) -> Range<String.Index> {
            rawIndices[offsets[range.lowerBound] ?? 0]..<rawIndices[offsets[range.upperBound] ?? rawIndices.count - 1]
        }

        var tokens: [Token] = []
        var lastSentence = -1
        var clause = 0
        var previousEnd = text.startIndex
        for tag in tagger.tag(text) {
            let surface = Self.trimmingPunctuation(String(text[tag.range]))
            guard !surface.isEmpty else { continue }
            let trimmedRange = text[tag.range].range(of: surface) ?? tag.range
            // Token ranges can overlap (joined names), so the gap may be empty.
            let gap = previousEnd < tag.range.lowerBound ? text[previousEnd..<tag.range.lowerBound] : ""
            let opensClause = languageCode == "de" && Self.germanClauseOpeners.contains(fold(surface))
            if tag.sentence != lastSentence || opensClause || gap.contains(where: { ",;:()«»\"–—".contains($0) }) {
                clause += 1
            }
            tokens.append(Token(
                range: rawRange(trimmedRange),
                surface: surface,
                lemma: tag.lemma,
                lexicalClass: tag.lexicalClass,
                isTaggedName: tag.isName,
                isSentenceInitial: tag.sentence != lastSentence,
                clause: clause
            ))
            lastSentence = tag.sentence
            previousEnd = max(previousEnd, tag.range.upperBound)
        }
        if !separablePrefixes.isEmpty { joinSeparableVerbs(&tokens) }
        return tokens
    }

    /// "Ich stehe früh auf." → `stehe` also counts as `aufstehen`, and the
    /// clause-final particle is consumed. Only clause-final particles qualify,
    /// which keeps "um … zu" and ordinary prepositions out.
    ///
    /// A verb in the clause that, with this particle, forms an allowed
    /// separable verb wins (works without a tagger). Otherwise the nearest
    /// tagger-identified verb is joined so an unknown is reported whole
    /// ("anrufen", not "rufen").
    private func joinSeparableVerbs(_ tokens: inout [Token]) {
        for i in tokens.indices {
            let particle = fold(tokens[i].surface)
            guard separablePrefixes.contains(particle) else { continue }
            let isClauseFinal = i == tokens.count - 1 || tokens[i + 1].clause != tokens[i].clause
            guard isClauseFinal else { continue }

            let clauseIndices = stride(from: i - 1, through: 0, by: -1)
                .prefix { tokens[$0].clause == tokens[i].clause }
            var joined = false
            for j in clauseIndices {
                let surfaceKey = fold(tokens[j].surface)
                var lemmas = verbMatches(surfaceKey, prefix: particle)
                for base in (aliasKeys[surfaceKey] ?? []) + [tokens[j].lemma.map(fold)].compactMap({ $0 })
                where allowedKeys.contains(particle + base) {
                    lemmas.insert(particle + base)
                }
                if let lemma = lemmas.sorted().first {
                    tokens[j].separableLemma = lemma
                    tokens[i].isConsumedParticle = true
                    joined = true
                    break
                }
            }
            guard !joined else { continue }
            if let j = clauseIndices.first(where: { tokens[$0].lexicalClass == .verb }) {
                let base = (tokens[j].lemma ?? tokens[j].surface).lowercased()
                tokens[j].separableLemma = particle + base
                tokens[i].isConsumedParticle = true
            }
        }
    }

    // MARK: - Analysis

    private enum Kind { case number, name, function, known, unknown(String) }
    private struct Analysis { let kind: Kind; let keys: Set<String> }

    private func analyze(_ token: Token, tagger: Tagger) -> Analysis {
        if token.isConsumedParticle { return Analysis(kind: .function, keys: []) }
        if isNumber(token) { return Analysis(kind: .number, keys: []) }

        var keys = baseKeys(token)
        if token.isTaggedName || !keys.isDisjoint(with: nameKeys) {
            return Analysis(kind: .name, keys: keys)
        }
        if !keys.isDisjoint(with: functionKeys) { return Analysis(kind: .function, keys: keys) }
        if !keys.isDisjoint(with: allowedKeys) { return Analysis(kind: .known, keys: keys) }

        keys.formUnion(fallbackKeys(surface: token.surface, lemma: token.lemma, lexicalClass: token.lexicalClass, tagger: tagger))
        if isAccepted(keys) { return Analysis(kind: .known, keys: keys) }

        for parts in splits(of: token.surface) {
            let partKeys = parts.map { fragmentKeys($0, tagger: tagger) }
            if partKeys.allSatisfy(isAccepted) {
                return Analysis(kind: .known, keys: keys.union(partKeys.joined()))
            }
        }
        if looksLikeUntaggedName(token) { return Analysis(kind: .name, keys: keys) }
        return Analysis(kind: .unknown(display(for: token, tagger: tagger)), keys: keys)
    }

    private func isAccepted(_ keys: Set<String>) -> Bool {
        !keys.isDisjoint(with: allowedKeys) || !keys.isDisjoint(with: functionKeys)
    }

    private func baseKeys(_ token: Token) -> Set<String> {
        var keys: Set<String> = [fold(token.surface)]
        if let lemma = token.lemma { keys.formUnion(Self.variantKeys(of: lemma, languageCode: languageCode, functionKeys: [])) }
        if let joined = token.separableLemma { keys.insert(fold(joined)) }
        for key in keys { keys.formUnion(aliasKeys[key] ?? []) }
        return keys
    }

    /// Single-word morphology, tried once the direct candidates have missed:
    /// verb stem + ending, German prefix verbs, clitic stripping (es/it) and
    /// noun/adjective endings.
    private func fallbackKeys(surface: String, lemma: String?, lexicalClass: NLTag?, tagger: Tagger) -> Set<String> {
        let surfaceKey = fold(surface)
        let lemmaKey = lemma.map(fold)
        var keys = verbMatches(surfaceKey, prefix: nil)

        if languageCode == "de" {
            keys.formUnion(prefixVerbMatches(surfaceKey))
        }
        for entry in prefixedIrregulars where surfaceKey.hasPrefix(entry.prefix) {
            let rest = String(surfaceKey.dropFirst(entry.prefix.count))
            let bases = (aliasKeys[rest] ?? []) + (languageCode == "de" ? aliasKeys["ge" + rest] ?? [] : [])
            if bases.contains(entry.base) { keys.insert(entry.verb) }
        }

        if !cliticSuffixes.isEmpty, lexicalClass == .verb || lemma == nil || lemmaKey == surfaceKey {
            for suffix in cliticSuffixes where surfaceKey.hasSuffix(suffix) && surfaceKey.count - suffix.count >= 2 {
                let stem = String(surfaceKey.dropLast(suffix.count))
                keys.insert(stem)
                keys.formUnion(verbMatches(stem, prefix: nil))
                if let stemLemma = tagger.isolatedLemma(of: stem) { keys.insert(fold(stemLemma)) }
            }
        }

        let nominal = lexicalClass == .noun || lexicalClass == .adjective || lemma == nil
        if nominal {
            var nominalKeys = Set<String>()
            for base in [surfaceKey, lemmaKey].compactMap({ $0 }) {
                for (from, to) in inflectionSuffixes where base.hasSuffix(from) && base.count - from.count >= 2 {
                    nominalKeys.insert(String(base.dropLast(from.count)) + to)
                }
            }
            // German umlaut plurals: Brüder → bruder, Hände → hand(e), Bücher → buch(er).
            if languageCode == "de" {
                for key in nominalKeys.union([surfaceKey]) {
                    if let plain = Self.removingLastUmlaut(key) { nominalKeys.insert(plain) }
                }
            }
            keys.formUnion(nominalKeys)
        }
        for key in keys { keys.formUnion(aliasKeys[key] ?? []) }
        return keys
    }

    /// German verbs written with their particle attached: aufsteht (subordinate
    /// clause), aufzustehen (zu-infinitive), eingekauft / aufgestanden
    /// (participles, regular or via aliases).
    private func prefixVerbMatches(_ key: String) -> Set<String> {
        var result = Set<String>()
        for prefix in separablePrefixes where key.hasPrefix(prefix) && key.count - prefix.count >= 3 {
            let rest = String(key.dropFirst(prefix.count))
            var rests = [rest]
            if rest.hasPrefix("zu"), rest.count > 4 { rests.append(String(rest.dropFirst(2))) }
            for candidate in rests {
                result.formUnion(verbMatches(candidate, prefix: prefix))
                for base in aliasKeys[candidate] ?? [] where allowedKeys.contains(prefix + base) {
                    result.insert(prefix + base)
                }
            }
        }
        return result
    }

    /// Allowed verbs this form can be a regular inflection of.
    private func verbMatches(_ key: String, prefix: String?) -> Set<String> {
        guard !verbStems.isEmpty else { return [] }
        var result = Set<String>()
        let characters = Array(key)
        for cut in stride(from: characters.count, through: 1, by: -1) {
            guard let entries = verbStems[String(characters[..<cut])] else { continue }
            let ending = String(characters[cut...])
            for entry in entries where entry.requiredPrefix == prefix && entry.endings.contains(ending) {
                result.insert(entry.lemmaKey)
            }
        }
        // German ge-participle: ge + stem + (e)t / en (gekauft, gearbeitet, gebacken).
        if languageCode == "de", key.hasPrefix("ge"), key.count > 4 {
            let rest = Array(key.dropFirst(2))
            for cut in stride(from: rest.count - 1, through: 2, by: -1) {
                let ending = String(rest[cut...])
                guard ["t", "et", "en"].contains(ending), let entries = verbStems[String(rest[..<cut])] else { continue }
                for entry in entries where entry.requiredPrefix == prefix {
                    result.insert(entry.lemmaKey)
                }
            }
        }
        return result
    }

    /// Candidate keys for a piece of a split token (elision remainder, hyphen
    /// part, compound head/tail).
    private func fragmentKeys(_ fragment: String, tagger: Tagger) -> Set<String> {
        var keys: Set<String> = [fold(fragment), fold(fragment.replacingOccurrences(of: "'", with: ""))]
        let lemma = tagger.isolatedLemma(of: fragment)
        if let lemma { keys.insert(fold(lemma)) }
        for key in keys { keys.formUnion(aliasKeys[key] ?? []) }
        if !isAccepted(keys) {
            keys.formUnion(fallbackKeys(surface: fragment, lemma: lemma, lexicalClass: nil, tagger: tagger))
        }
        return keys
    }

    /// Ways to split a token into independently-known parts.
    private func splits(of surface: String) -> [[String]] {
        var result: [[String]] = []
        if let elision = elisionSplit(of: surface) { result.append([elision.head, elision.tail]) }
        // Hyphenated: dit-il, a-t-elle.
        let hyphenParts = surface.split(separator: "-").map(String.init)
        if hyphenParts.count > 1 { result.append(hyphenParts) }
        // German compounds: Bahnhofsuhr → Bahnhof(s) + Uhr.
        if languageCode == "de", surface.first?.isUppercase == true {
            result.append(contentsOf: compoundSplits(of: surface, depth: 2))
        }
        return result
    }

    /// Elision glued to its host: dell'isola, un'amica, nell'acqua.
    private func elisionSplit(of surface: String) -> (head: String, tail: String)? {
        guard let apostrophe = surface.firstIndex(of: "'"),
              apostrophe != surface.index(before: surface.endIndex) else { return nil }
        return (String(surface[...apostrophe]), String(surface[surface.index(after: apostrophe)...]))
    }

    private func compoundSplits(of word: String, depth: Int) -> [[String]] {
        let characters = Array(word)
        guard depth > 0, characters.count >= 6 else { return [] }
        var result: [[String]] = []
        for cut in stride(from: characters.count - 3, through: 3, by: -1) {
            let tail = String(characters[cut...]).capitalized
            let head = String(characters[..<cut])
            guard isKnownFragment(tail) else { continue }
            var heads = [head]
            for linker in compoundLinkers where head.lowercased().hasSuffix(linker) && head.count - linker.count >= 3 {
                heads.append(String(head.dropLast(linker.count)))
            }
            for candidate in heads {
                if isKnownFragment(candidate) {
                    result.append([candidate, tail])
                } else if let inner = compoundSplits(of: candidate, depth: depth - 1).first {
                    result.append(inner + [tail])
                }
            }
            if !result.isEmpty { break }
        }
        return result
    }

    /// Cheap membership test for compound pieces (no tagger: compound
    /// splitting tries many cuts).
    private func isKnownFragment(_ fragment: String) -> Bool {
        let key = fold(fragment)
        var keys: Set<String> = [key]
        for (from, to) in inflectionSuffixes where key.hasSuffix(from) && key.count - from.count >= 2 {
            keys.insert(String(key.dropLast(from.count)) + to)
        }
        return !keys.isDisjoint(with: allowedKeys)
    }

    private func isNumber(_ token: Token) -> Bool {
        if token.lexicalClass == .number { return true }
        let hasDigit = token.surface.contains(where: \.isNumber)
        return hasDigit && !token.surface.contains(where: \.isLetter)
    }

    /// Capitalised mid-sentence and unknown → a name NLTagger didn't tag.
    /// Not used for German, where every noun is capitalised.
    private func looksLikeUntaggedName(_ token: Token) -> Bool {
        languageCode != "de" && !token.isSentenceInitial && token.surface.first?.isUppercase == true
    }

    private func display(for token: Token, tagger: Tagger) -> String {
        if let joined = token.separableLemma { return joined }
        // "nell'acqua" is unknown because of "acqua", so report that.
        if let elision = elisionSplit(of: token.surface), functionKeys.contains(fold(elision.head)) {
            let tail = tagger.isolatedLemma(of: elision.tail) ?? elision.tail
            return languageCode == "de" ? tail : tail.lowercased()
        }
        if let lemma = token.lemma, !lemma.isEmpty {
            return languageCode == "de" ? lemma : lemma.lowercased()
        }
        return languageCode == "de" ? token.surface : token.surface.lowercased()
    }

    private func fold(_ s: String) -> String { Self.fold(s, languageCode: languageCode) }

    /// Strips punctuation NLTagger sometimes leaves on a token ("día."), but
    /// keeps a trailing elision apostrophe ("l'") and inner hyphens.
    private static func trimmingPunctuation(_ surface: String) -> String {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'"))
        var scalars = Substring(surface).unicodeScalars
        while let first = scalars.first, edges.contains(first) || first == "'" { scalars.removeFirst() }
        while let last = scalars.last, edges.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    // MARK: - Verb index

    private static func buildVerbIndex(
        words: [StoryWord], lexicon: StoryLexicon, separablePrefixes: Set<String>
    ) -> [String: [VerbEntry]] {
        let code = lexicon.language
        let classes = (lexicon.verbEndings ?? [:])
            .map { (ending: fold($0.key, languageCode: code), endings: Set($0.value.map { fold($0, languageCode: code) })) }
            .sorted { $0.ending.count > $1.ending.count }
        guard !classes.isEmpty else { return [:] }
        let vowelAlternations = (lexicon.stemAlternations ?? []).filter { $0.count == 2 }
        let finalAlternations = (lexicon.stemFinalAlternations ?? []).filter { $0.count == 2 }

        var index: [String: [VerbEntry]] = [:]
        func register(_ key: String, lemmaKey: String, prefix: String?) {
            guard let verbClass = classes.first(where: { key.hasSuffix($0.ending) && key.count > $0.ending.count }) else { return }
            let stem = String(key.dropLast(verbClass.ending.count))
            // Short stems only for short verbs (dar → d-, ir → -, ver → v-).
            guard stem.count >= (key.count <= 3 ? 1 : 2) else { return }
            var stems: Set<String> = [stem]
            for pair in vowelAlternations {
                if let alternated = alternateLastVowel(of: stem, from: pair[0], to: pair[1]) { stems.insert(alternated) }
            }
            for base in stems {
                for pair in finalAlternations where base.hasSuffix(pair[0]) {
                    stems.insert(String(base.dropLast(pair[0].count)) + pair[1])
                }
            }
            for s in stems {
                index[s, default: []].append(VerbEntry(lemmaKey: lemmaKey, endings: verbClass.endings, requiredPrefix: prefix))
            }
        }

        for word in words {
            let folded = fold(word.lemma, languageCode: code)
            let base = reflexiveBase(of: folded, languageCode: code)
            guard !base.contains(" "), isVerb(word, folded: base, classes: classes.map(\.ending), languageCode: code) else { continue }
            register(base, lemmaKey: base, prefix: nil)
            for prefix in separablePrefixes where base.hasPrefix(prefix) && base.count - prefix.count >= 4 {
                register(String(base.dropFirst(prefix.count)), lemmaKey: base, prefix: prefix)
            }
        }
        return index
    }

    private static func isVerb(_ word: StoryWord, folded: String, classes: [String], languageCode: String) -> Bool {
        if let pos = word.partOfSpeech { return pos.lowercased().hasPrefix("verb") }
        // No POS: infer from the infinitive ending (German verbs are lowercase).
        if languageCode == "de", word.lemma.first?.isUppercase == true { return false }
        return classes.contains { folded.hasSuffix($0) && folded.count > $0.count + 1 }
    }

    /// "brueder" → "bruder": undo the last transliterated umlaut (ae/oe/ue;
    /// aeu → au).
    private static func removingLastUmlaut(_ key: String) -> String? {
        let candidates = ["aeu", "ae", "oe", "ue"].compactMap { pattern in
            key.range(of: pattern, options: .backwards).map { (pattern, $0) }
        }
        guard let (pattern, range) = candidates.max(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
        // "ue" right after "a" is part of "aeu", "eu" of a diphthong, "que"… leave those.
        if pattern == "ue", range.lowerBound > key.startIndex,
           "aeq".contains(key[key.index(before: range.lowerBound)]) { return nil }
        let replacement = pattern == "aeu" ? "au" : String(pattern.prefix(1))
        return key.replacingCharacters(in: range, with: replacement)
    }

    /// Applies `from → to` to the stem's last vowel (querer: quer → quier).
    private static func alternateLastVowel(of stem: String, from: String, to: String) -> String? {
        guard let range = stem.range(of: from, options: .backwards) else { return nil }
        let after = stem[range.upperBound...]
        guard !after.contains(where: { "aeiou".contains($0) }) else { return nil }
        return stem.replacingCharacters(in: range, with: to)
    }

    // MARK: - Normalisation (shared with tests and story prompt building)

    /// Case-folds, normalises apostrophes, and strips accents (es/fr/it, keeping
    /// ñ) or transliterates umlauts (de).
    static func fold(_ s: String, languageCode: String) -> String {
        let lower = s.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        if languageCode == "de" {
            var out = ""
            out.reserveCapacity(lower.count)
            for ch in lower {
                switch ch {
                case "ä": out += "ae"
                case "ö": out += "oe"
                case "ü": out += "ue"
                case "ß": out += "ss"
                default: out.append(ch)
                }
            }
            return out
        }
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in lower.decomposedStringWithCanonicalMapping.unicodeScalars {
            if (0x300...0x36F).contains(scalar.value) {
                if languageCode == "es", scalar.value == 0x303, previous == "n" { scalars.append(scalar) }
                continue
            }
            scalars.append(scalar)
            previous = scalar
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// Keys a known lemma unlocks: itself, its base verb when reflexive
    /// (levantarse, se lever, s'amuser, sich freuen, alzarsi), and the content
    /// words of a multiword phrase (carta di credito → carta, credito).
    static func variantKeys(of lemma: String, languageCode: String, functionKeys: Set<String>) -> Set<String> {
        let folded = fold(lemma, languageCode: languageCode)
        var keys: Set<String> = [folded]
        let base = reflexiveBase(of: folded, languageCode: languageCode)
        keys.insert(base)
        let parts = phraseParts(of: base)
        if parts.count > 1 {
            keys.formUnion(parts.filter { !functionKeys.contains($0) })
        }
        return keys
    }

    private static func reflexiveBase(of folded: String, languageCode: String) -> String {
        for prefix in ["se ", "s'", "sich "] where folded.hasPrefix(prefix) && folded.count > prefix.count + 2 {
            return String(folded.dropFirst(prefix.count))
        }
        if languageCode == "es", folded.hasSuffix("se"), ["ar", "er", "ir"].contains(String(folded.dropLast(2).suffix(2))) {
            return String(folded.dropLast(2))
        }
        if languageCode == "it", folded.hasSuffix("rsi"), folded.count > 5 {
            return String(folded.dropLast(3)) + "re"
        }
        return folded
    }

    private static func phraseParts(of lemma: String) -> [String] {
        lemma.split(separator: " ").map(String.init)
    }
}

/// The outcome of a vocabulary check, stored with the story.
nonisolated struct StoryCoverageReport: Codable, Equatable, Sendable {
    enum Failure: Codable, Equatable, Sendable {
        case lowCoverage
        case tooManyUnknownLemmas
        case newWordsUnderused([String])
        case tooShort
        case tooLong
    }

    /// Known content tokens / content tokens (story + questions). Function
    /// words, names, numbers and punctuation are excluded from both.
    var coverage: Double
    var contentTokenCount: Int
    var unknownTokenCount: Int
    /// Unique unknown lemmas in first-seen order.
    var unknownLemmas: [String]
    /// New lemma → times it appears in the story text (questions excluded).
    var newWordUses: [String: Int]
    /// Word tokens in the story text (questions excluded).
    var wordCount: Int
    var failures: [Failure]

    var passed: Bool { failures.isEmpty }

    var underusedNewWords: [String] {
        for case .newWordsUnderused(let words) in failures { return words }
        return []
    }
}

// MARK: - NLTagger wrapper

/// One NLTagger per check, reused for whole texts and for isolated words
/// (clitic stems, elision remainders).
private nonisolated final class Tagger {
    struct Tag {
        let range: Range<String.Index>
        let lemma: String?
        let lexicalClass: NLTag?
        let isName: Bool
        let sentence: Int
    }

    private let language: NLLanguage
    private let usesLemmas: Bool
    private let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass, .nameType])
    private let wordTagger = NLTagger(tagSchemes: [.lemma])
    private var isolatedCache: [String: String?] = [:]

    init(languageCode: String, usesLemmas: Bool) {
        self.language = NLLanguage(rawValue: languageCode)
        self.usesLemmas = usesLemmas
    }

    func tag(_ text: String) -> [Tag] {
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        tagger.setLanguage(language, range: whole)

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentenceTokenizer.setLanguage(language)
        let sentences = sentenceTokenizer.tokens(for: whole)

        var tags: [Tag] = []
        let names: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(
            in: whole, unit: .word, scheme: .lexicalClass,
            // No .joinNames: without a name model it glues ordinary phrases
            // ("Die Polizei") into one token. Names are tagged word by word.
            options: [.omitWhitespace, .omitPunctuation]
        ) { lexicalClass, range in
            let lemma = usesLemmas ? tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue : nil
            let nameType = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
            let sentence = sentences.firstIndex { $0.contains(range.lowerBound) } ?? 0
            tags.append(Tag(
                range: range,
                lemma: lemma.flatMap { $0.isEmpty ? nil : $0 },
                lexicalClass: lexicalClass,
                isName: nameType.map(names.contains) ?? false,
                sentence: sentence
            ))
            return true
        }
        return tags
    }

    func isolatedLemma(of word: String) -> String? {
        guard usesLemmas else { return nil }
        if let cached = isolatedCache[word] { return cached }
        wordTagger.string = word
        wordTagger.setLanguage(language, range: word.startIndex..<word.endIndex)
        let lemma = wordTagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0?.rawValue
        let result = lemma.flatMap { $0.isEmpty ? nil : $0 }
        isolatedCache[word] = result
        return result
    }
}
