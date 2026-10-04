import Foundation
@preconcurrency import AVFoundation

@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    /// Retained delegate box for the Apple-synth fallback. `AVSpeechSynthesizer`
    /// holds its delegate weakly, so this has to outlive the utterance.
    private lazy var synthDelegate: SynthesizerCompletionBox = {
        let box = SynthesizerCompletionBox()
        synthesizer.delegate = box
        return box
    }()

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
        .english: ["Rocko", "Reed", "Eddy", "Daniel", "Arthur"],
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

    /// Speak `text` as Walter and suspend until the audio has finished
    /// playing. This is what lets the voice call reveal one speech bubble
    /// per sentence in time with his voice instead of dumping a paragraph
    /// on screen and talking over it.
    ///
    /// Returns early — without waiting — if the surrounding task is
    /// cancelled (the user hung up mid-sentence).
    func speakAsWalterAndWait(_ text: String, languageCode: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let code = languageCode ?? defaultLanguageCode()

        do {
            let data = try await OpenAITTSClient.shared.fetchAudio(
                text: trimmed,
                voice: "onyx",
                instructions: Self.walterInstructions(for: code)
            )
            if Task.isCancelled { return }
            await WalrusAudioPlayer.shared.playAndWait(data)
        } catch {
            if Task.isCancelled { return }
            await speakViaAppleAndWait(trimmed, languageCode: code)
        }
    }

    /// Warm the TTS disk cache for a line we're about to need. Fired for
    /// sentence N+1 while sentence N is still playing, so the pause between
    /// Walter's speech bubbles is silence-length, not network-length.
    func prefetchAsWalter(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let code = languageCode ?? defaultLanguageCode()
        Task {
            _ = try? await OpenAITTSClient.shared.fetchAudio(
                text: trimmed,
                voice: "onyx",
                instructions: Self.walterInstructions(for: code)
            )
        }
    }

    func stop() {
        openAITask?.cancel()
        openAITask = nil
        WalrusAudioPlayer.shared.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthDelegate.finish()
    }

    private func defaultLanguageCode() -> String {
        (OnboardingStore.targetLanguage ?? .spanish).bcp47
    }

    private func speakViaApple(_ text: String, languageCode: String) {
        synthesizer.speak(utterance(for: text, languageCode: languageCode))
    }

    /// Apple-synth twin of `speakAsWalterAndWait`, used when the TTS proxy
    /// is unreachable. Waits on the synthesizer's delegate, with a
    /// generous character-count-derived backstop in case the callback
    /// never lands.
    private func speakViaAppleAndWait(_ text: String, languageCode: String) async {
        let utterance = utterance(for: text, languageCode: languageCode)
        // ~13 characters/second at our 0.88 rate, plus the pre-utterance
        // delay and slack. Only ever used if the delegate goes missing.
        let backstop = 1.5 + Double(text.count) / 13.0
        await synthDelegate.wait(backstop: backstop) { [synthesizer] in
            synthesizer.speak(utterance)
        }
    }

    private func utterance(for text: String, languageCode: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolvedVoice(for: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 0.78
        utterance.preUtteranceDelay = 0.4
        return utterance
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
        case "en-GB":
            return ("English", "Standard British English accent (Received Pronunciation), not American.")
        default:
            return ("Spanish", "Spain accent, not Latin American.")
        }
    }
}

// MARK: - Apple synthesizer completion bridge

/// Turns `AVSpeechSynthesizer`'s delegate callbacks into an awaitable
/// call. Kept as a separate object because the synthesizer holds its
/// delegate weakly and because the callbacks arrive off the main actor.
@MainActor
private final class SynthesizerCompletionBox: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var backstopTask: Task<Void, Never>?

    /// Runs `speak`, then suspends until the synthesizer reports the
    /// utterance finished or cancelled — or until `backstop` seconds pass.
    func wait(backstop: Double, speak: @escaping () -> Void) async {
        finish()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
            backstopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(backstop * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
            speak()
        }
    }

    /// Resume any pending waiter. Idempotent — safe to call from `stop()`
    /// whether or not anything is waiting.
    func finish() {
        backstopTask?.cancel()
        backstopTask = nil
        let cont = continuation
        continuation = nil
        cont?.resume()
    }
}

extension SynthesizerCompletionBox: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
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
