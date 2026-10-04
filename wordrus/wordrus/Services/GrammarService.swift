import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The verdict on one of the learner's sentences.
///
/// `unavailable` is deliberately distinct from `clean`: Apple Foundation
/// Models isn't present on every device, and on those the check never runs
/// at all. Collapsing the two would have the app tell a learner their
/// sentence was correct when nothing ever looked at it.
enum GrammarCheckOutcome {
    /// No check happened — model missing, errored, or the text was too
    /// short to be worth judging. Vouches for nothing.
    case unavailable
    /// Checked, and there was nothing worth teaching.
    case clean
    /// Checked, with the full corrected sentence.
    case corrected(String)
}

/// Checks a user's chat reply for grammar, conjugation, or spelling
/// errors via Apple Foundation Models. Conservative by design — only
/// flags real errors, not stylistic choices or dictation punctuation.
@MainActor
final class GrammarService {
    static let shared = GrammarService()

    /// Cache key → corrected sentence. Empty-string value marks "checked,
    /// no errors" so we don't re-query the model for the same input.
    private var cache: [String: String] = [:]

    private init() {}

    func check(
        _ text: String,
        language: TargetLanguage
    ) async -> GrammarCheckOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't waste a model call on trivial replies.
        guard trimmed.count >= 3 else { return .unavailable }

        let key = "\(language.rawValue)|\(trimmed)"
        if let cached = cache[key] {
            return cached.isEmpty ? .clean : .corrected(cached)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            do {
                let instructions = """
                You are a gentle \(language.englishName) tutor. Inspect the user's text \
                for genuine grammar, conjugation, agreement, or spelling errors.

                Output rules:
                - Set `hasError = false` and leave `corrected` empty if the text is correct, \
                  or only differs from "standard" in casual/informal style.
                - Set `hasError = true` and write the FULL corrected sentence in `corrected` \
                  only when there is a real error worth teaching.
                - The text is DICTATED SPEECH. Missing full stops, commas, question marks, \
                  or a lowercase first word are the transcriber's doing, not the learner's — \
                  they are NOT errors. Never set `hasError` for punctuation or sentence-opening \
                  capitalisation alone. Accents and mid-sentence capitals DO count \
                  (esta/está, haus/Haus).
                - Do NOT translate, do NOT add commentary, do NOT quote.
                - Keep the user's meaning and tone — only fix mistakes.
                """
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: Prompt(trimmed),
                    generating: GrammarOutput.self
                )
                let out = response.content
                if out.hasError {
                    let corrected = out.corrected
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                    if !corrected.isEmpty,
                       corrected.caseInsensitiveCompare(trimmed) != .orderedSame {
                        cache[key] = corrected
                        return .corrected(corrected)
                    }
                }
                cache[key] = ""  // sentinel: checked, nothing to fix
                return .clean
            } catch {
                #if DEBUG
                print("GrammarService failed: \(error)")
                #endif
                return .unavailable
            }
        }
        #endif
        // No Foundation Models on this device — nothing checked this.
        return .unavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GrammarOutput {
    @Guide(description: "True only if there is a real grammar, conjugation, agreement, or spelling error worth correcting. False for stylistic or informal-but-valid text.")
    var hasError: Bool

    @Guide(description: "If hasError is true, the FULL corrected sentence in the user's target language — no labels, no commentary. Empty when hasError is false.")
    var corrected: String
}
#endif
