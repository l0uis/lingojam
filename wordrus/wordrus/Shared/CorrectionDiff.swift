import Foundation

/// Word-level diff between what the learner said and the corrected
/// sentence, so the call UI can point at the exact words that changed
/// rather than showing two sentences and leaving the learner to spot the
/// difference themselves.
///
/// Diacritics and mid-sentence capitals are compared **exactly**, because
/// in the languages Wordrus teaches those *are* the corrections:
/// `esta` → `está`, `das haus` → `das Haus`. Folding them away would hide
/// the very fix the learner needs to see.
///
/// Sentence punctuation and the capital on the first word are ignored.
/// The learner speaks their answer, so it's `SFSpeechRecognizer` — not
/// them — that decides whether a full stop lands at the end or the first
/// word arrives capitalised. Flagging those would mark someone wrong for
/// something they never said.
enum CorrectionDiff {
    enum Change {
        /// Survives unchanged from the original into the correction.
        case unchanged
        /// Dropped from the original, or newly introduced by the correction.
        case changed
    }

    struct Token: Identifiable {
        let id: Int
        let text: String
        let change: Change
    }

    struct Result {
        /// The learner's own words; `.changed` tokens are the ones the
        /// correction removed or replaced.
        let original: [Token]
        /// The corrected sentence; `.changed` tokens are the fixes.
        let corrected: [Token]

        /// How many words the correction introduced. Not surfaced in the
        /// UI — the highlighting carries that — but it's the clearest way
        /// to assert on a diff.
        var fixCount: Int {
            corrected.filter { $0.change == .changed }.count
        }

        /// False when the two sentences are word-for-word identical — the
        /// caller should then treat the reply as clean and show no
        /// correction at all.
        var hasChanges: Bool {
            corrected.contains { $0.change == .changed }
                || original.contains { $0.change == .changed }
        }
    }

    static func compare(original: String, corrected: String) -> Result {
        let originalWords = tokenize(original)
        let correctedWords = tokenize(corrected)
        // Matched on normalised keys, displayed as the learner said them.
        let (keptOriginal, keptCorrected) = longestCommonSubsequence(
            matchKeys(for: originalWords),
            matchKeys(for: correctedWords)
        )

        return Result(
            original: originalWords.enumerated().map { index, word in
                Token(id: index, text: word, change: keptOriginal.contains(index) ? .unchanged : .changed)
            },
            corrected: correctedWords.enumerated().map { index, word in
                Token(id: index, text: word, change: keptCorrected.contains(index) ? .unchanged : .changed)
            }
        )
    }

    /// Whitespace split, punctuation left attached to its word. Keeping
    /// `hola,` as one token means a missing comma reads as one highlighted
    /// word rather than a stray floating mark.
    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Sentence punctuation that says nothing about the learner's command
    /// of the language. Note the apostrophe is **absent** on purpose:
    /// `Di'` and `l'eau` carry meaning, so a missing one is a real fix.
    private static let ignoredPunctuation = CharacterSet(charactersIn: ".,;:!?¡¿…\"«»“”()[]—–-")

    /// The form a token is *compared* by. Strips sentence punctuation from
    /// both ends, and lowercases the opening word so a capital the
    /// recogniser chose doesn't read as an error. Everything else — accents,
    /// mid-sentence capitals, internal apostrophes — is left intact.
    private static func matchKeys(for tokens: [String]) -> [String] {
        tokens.enumerated().map { index, token in
            let trimmed = token.trimmingCharacters(in: ignoredPunctuation)
            // An all-punctuation token trims to nothing; keep the original
            // so two different stray marks don't compare equal.
            let key = trimmed.isEmpty ? token : trimmed
            return index == 0 ? key.lowercased() : key
        }
    }

    /// Standard LCS over the two token arrays, returning the index sets
    /// that survive on each side. Sentences here are a handful of words,
    /// so the quadratic table costs nothing.
    private static func longestCommonSubsequence(
        _ lhs: [String],
        _ rhs: [String]
    ) -> (lhs: Set<Int>, rhs: Set<Int>) {
        guard !lhs.isEmpty, !rhs.isEmpty else { return ([], []) }

        var lengths = Array(
            repeating: Array(repeating: 0, count: rhs.count + 1),
            count: lhs.count + 1
        )
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                lengths[i][j] = lhs[i] == rhs[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var keptLHS: Set<Int> = []
        var keptRHS: Set<Int> = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i] == rhs[j] {
                keptLHS.insert(i)
                keptRHS.insert(j)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keptLHS, keptRHS)
    }
}
