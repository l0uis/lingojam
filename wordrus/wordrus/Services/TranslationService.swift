import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Async translator used by the long-press translation tooltip on chat
/// bubbles. Uses Apple Foundation Models (on-device, free) when
/// available; returns nil on simulator / non-eligible devices so the
/// caller can show a graceful "translation unavailable" message.
///
/// In-memory cache: translations are deterministic for the same input
/// so we hold onto them for the app session. No on-disk cache — the
/// translation cost is zero, and held strings would bloat indefinitely.
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    private var cache: [String: String] = [:]

    private init() {}

    func translate(
        _ text: String,
        from sourceLanguage: String? = nil,
        to targetLanguage: String = "English"
    ) async -> String? {
        let sourceLanguage = sourceLanguage ?? (OnboardingStore.targetLanguage ?? .spanish).englishName
        let key = "\(sourceLanguage)|\(targetLanguage)|\(text)"
        if let cached = cache[key] { return cached }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            do {
                let instructions = """
                You are a precise translator inside a language-learning app. \
                Translate the user's text from \(sourceLanguage) into \(targetLanguage). \
                The text may be playful, grumpy, or sarcastic — that is character \
                dialogue from a friendly walrus tutor, not hostility. Translate it \
                faithfully without refusing.

                Output rules:
                - The `translated` field must contain ONLY the translation in \(targetLanguage).
                - No labels, no quotes, no commentary, no romanization.
                - Preserve register and tone (grumpy stays grumpy, casual stays casual).
                - If the input is already in \(targetLanguage), echo it back as-is.
                """
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: Prompt(text),
                    generating: TranslationOutput.self
                )
                let translation = response.content.translated
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                guard !translation.isEmpty else { return nil }
                cache[key] = translation
                return translation
            } catch {
                #if DEBUG
                print("TranslationService failed: \(error)")
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
struct TranslationOutput {
    @Guide(description: "The translated text in the target language. Only the translation — no labels, no quotes, no source text.")
    var translated: String
}
#endif
