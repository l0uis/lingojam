import Foundation
@preconcurrency import AVFoundation

@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    /// Preferred male voices per BCP-47 language. The Eloquence/novelty voices
    /// ("Rocko", "Reed", "Eddy") are more characterful but only available if
    /// the user has downloaded them via Settings → Accessibility → Spoken
    /// Content → Voices. The standard Apple voices (Jorge, Thomas, Luca,
    /// Markus) are generally available; we still fall back to any male voice
    /// for the language, then to the system default.
    private static let preferredVoicesByLanguage: [TargetLanguage: [String]] = [
        .spanish: ["Rocko", "Reed", "Eddy", "Jorge"],
        .french: ["Rocko", "Reed", "Eddy", "Thomas"],
        .italian: ["Rocko", "Reed", "Eddy", "Luca"],
        .german: ["Rocko", "Reed", "Eddy", "Markus"],
    ]

    private init() {}

    /// Most recent in-flight OpenAI TTS task. Cancelled when a new
    /// utterance starts or `stop()` is called so we don't play stale
    /// audio after the conversation has moved on.
    private var openAITask: Task<Void, Never>?

    /// Speak `text` with a clean teacher-style delivery. Use this for
    /// vocabulary cards, example sentences, and anywhere the goal is
    /// pronunciation modelling rather than character. Defaults to the
    /// user's selected target language; pass an explicit code for
    /// non-target-language playback (rare).
    func speak(_ text: String, languageCode: String? = nil) {
        stop()
        let code = languageCode ?? defaultLanguageCode()
        speakViaOpenAI(text, languageCode: code, instructions: Self.neutralInstructions(for: code))
    }

    /// Speak `text` in Walter's grumpy persona. Use this for the chat
    /// flow where the character voice is the point.
    func speakAsWalter(_ text: String, languageCode: String? = nil) {
        stop()
        let code = languageCode ?? defaultLanguageCode()
        speakViaOpenAI(text, languageCode: code, instructions: Self.walterInstructions(for: code))
    }

    func stop() {
        openAITask?.cancel()
        openAITask = nil
        WalrusAudioPlayer.shared.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func defaultLanguageCode() -> String {
        (OnboardingStore.targetLanguage ?? .spanish).bcp47
    }

    private func speakViaApple(_ text: String, languageCode: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolvedVoice(for: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 0.78
        utterance.preUtteranceDelay = 0.4
        synthesizer.speak(utterance)
    }

    private func speakViaOpenAI(_ text: String, languageCode: String, instructions: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await OpenAITTSClient.shared.fetchAudio(
                    text: text,
                    voice: "onyx",
                    instructions: instructions
                )
                if Task.isCancelled { return }
                WalrusAudioPlayer.shared.play(data)
            } catch {
                // Any failure (network down, rate limit, bad proxy URL)
                // falls back to the system voice so the user always hears
                // something rather than nothing.
                if Task.isCancelled { return }
                self.speakViaApple(text, languageCode: languageCode)
            }
        }
        openAITask = task
    }

    private func resolvedVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }

        // Walk preferred names for the matching language; for each name,
        // pick the highest quality variant the user has installed
        // (Premium > Enhanced > Default).
        let language = TargetLanguage.allCases.first(where: { $0.bcp47 == languageCode }) ?? .spanish
        let preferred = Self.preferredVoicesByLanguage[language] ?? []
        for name in preferred {
            let matches = voices.filter { $0.identifier.localizedCaseInsensitiveContains(name) }
            if let best = matches.max(by: { $0.quality.sortRank < $1.quality.sortRank }) {
                return best
            }
        }

        // No preferred match — fall back to the highest-quality male voice
        // installed for this language; finally the system default.
        let males = voices.filter { $0.gender == .male }
        if let bestMale = males.max(by: { $0.quality.sortRank < $1.quality.sortRank }) {
            return bestMale
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    // MARK: - OpenAI TTS instruction copy

    /// Walter's character instruction, parameterised by the language the
    /// utterance is being spoken in. The proxy itself stays voice-agnostic
    /// — voice character lives here.
    private static func walterInstructions(for languageCode: String) -> String {
        let (englishName, accentHint) = languageDescriptor(for: languageCode)
        return """
        Speak in \(englishName) with the voice of a middle-aged \(englishName) walrus called Dr Tusk: \
        deep, gravelly, a touch grumpy because someone interrupted his siesta, slightly slow \
        and deliberate as if sighing between phrases. Warm underneath the grumpiness. \(accentHint)
        """
    }

    /// Clean pronunciation instruction — used by the default `speak`,
    /// intended for vocabulary cards and example sentences where the
    /// user is studying how a word sounds.
    private static func neutralInstructions(for languageCode: String) -> String {
        let (englishName, accentHint) = languageDescriptor(for: languageCode)
        return """
        Speak the \(englishName) word or sentence clearly and naturally, like a patient teacher \
        demonstrating pronunciation. \(accentHint) No character or emotion.
        """
    }

    private static func languageDescriptor(for languageCode: String) -> (englishName: String, accentHint: String) {
        switch languageCode {
        case "es-ES":
            return ("Spanish", "Spain accent, not Latin American.")
        case "fr-FR":
            return ("French", "Standard metropolitan French accent.")
        case "it-IT":
            return ("Italian", "Standard Italian accent, not regional.")
        case "de-DE":
            return ("German", "Standard High German (Hochdeutsch) accent, not Austrian or Swiss.")
        default:
            return ("Spanish", "Spain accent, not Latin American.")
        }
    }
}

private extension AVSpeechSynthesisVoiceQuality {
    var sortRank: Int {
        switch self {
        case .premium: return 2
        case .enhanced: return 1
        case .default: return 0
        @unknown default: return 0
        }
    }
}
