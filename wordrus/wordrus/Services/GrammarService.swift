import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Checks a user's chat reply for grammar, conjugation, or spelling
/// errors via Apple Foundation Models. Returns the full corrected
/// sentence if Walter would have written it differently, or nil if the
/// reply is already correct (or the model is unavailable). Conservative
/// by design — only flags real errors, not stylistic choices.
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
    ) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't waste a model call on trivial replies.
        guard trimmed.count >= 3 else { return nil }

        let key = "\(language.rawValue)|\(trimmed)"
        if let cached = cache[key] {
            return cached.isEmpty ? nil : cached
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
                        return corrected
                    }
                }
                cache[key] = ""  // sentinel: checked, nothing to fix
                return nil
            } catch {
                #if DEBUG
                print("GrammarService failed: \(error)")
                #endif
                return nil
            }
        }
        #endif
        return nil
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
