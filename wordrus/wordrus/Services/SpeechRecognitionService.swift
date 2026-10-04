import Foundation
import Observation
import Speech
@preconcurrency import AVFoundation

enum SpeechRecognitionError: Error {
    case recognizerUnavailable
    case noPermission
}

/// On-device speech-to-text for the chat input. Wraps `SFSpeechRecognizer`
/// + `AVAudioEngine` and exposes a live `transcript` so the chat view can
/// stream the user's words into the draft field as they speak.
///
/// Locale is set from `OnboardingStore.targetLanguage` at start time so
/// the recognizer expects the language the user is learning (Spanish,
/// French, etc.), not their system locale.
@Observable
@MainActor
final class SpeechRecognitionService {
    static let shared = SpeechRecognitionService()

    /// Live transcription. Updated as the recognizer reports partial
    /// results and finalised on `stopRecording`.
    private(set) var transcript: String = ""
    private(set) var isRecording: Bool = false
    /// Smoothed microphone loudness in 0...1, updated from the input tap
    /// while recording and reset to 0 when it stops. Drives the live level
    /// ring around the mic button in the voice call.
    private(set) var audioLevel: Double = 0
    /// Last user-facing error (e.g. "Spanish recognizer not available").
    /// Set when `startRecording` throws or the recognition task fails.
    private(set) var lastErrorMessage: String?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    /// Monotonic id bumped at the start of every recording. Recognition
    /// callbacks check this against the value captured at task creation
    /// so a stale "final result" from a torn-down session can't write
    /// its leftover transcription into the next session's transcript.
    private var sessionID: Int = 0

    private init() {}

    /// Asks the user for speech-recognition + microphone access. Safe
    /// to call multiple times — the system caches the decision after the
    /// first prompt.
    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }
        #else
        return true
        #endif
    }

    /// Begin a recognition session for `locale`. Throws if the recognizer
    /// for that language isn't available. iOS will use a network recognizer
    /// when the on-device model is missing — we never set
    /// `requiresOnDeviceRecognition` so that fallback works for every
    /// language pack we ship.
    func startRecording(locale: Locale) async throws {
        stopInternalSession()
        lastErrorMessage = nil

        // Walter's TTS holds the audio session in playback mode. Hand it
        // off explicitly before reconfiguring for record, otherwise the
        // category switch can silently fail and the mic captures nothing.
        SpeechService.shared.stop()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            lastErrorMessage = "Couldn't open the microphone: \(error.localizedDescription)"
            throw error
        }
        #endif

        guard let r = SFSpeechRecognizer(locale: locale) else {
            lastErrorMessage = "No speech recognizer for \(locale.identifier)."
            throw SpeechRecognitionError.recognizerUnavailable
        }
        guard r.isAvailable else {
            lastErrorMessage = "\(locale.identifier) recognizer is offline. Check internet or download the language pack in Settings → General → Keyboard → Dictation."
            throw SpeechRecognitionError.recognizerUnavailable
        }
        recognizer = r

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Deliberately NOT requiring on-device recognition — when the
        // on-device model isn't installed for this locale, iOS falls
        // back to its server recognizer transparently.
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            lastErrorMessage = "Microphone returned no audio format. Reset the audio session and try again."
            throw SpeechRecognitionError.recognizerUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            let level = Self.normalizedLevel(of: buffer)
            Task { @MainActor in self?.absorb(level: level) }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastErrorMessage = "Microphone wouldn't start: \(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            throw error
        }

        // Flip isRecording to true BEFORE clearing the transcript so any
        // SwiftUI listener that watches the transcript via
        // `.onChange(of: speech.transcript)` sees `isRecording == true`
        // and can wipe its mirrored draft. Otherwise the listener may
        // skip the clear and the previous session's text bleeds into
        // the next one.
        isRecording = true
        transcript = ""
        sessionID &+= 1
        let mySession = sessionID

        recognitionTask = r.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                // Drop callbacks from any task that isn't the current
                // session — stops a stale "final result" from the
                // previous recording from overwriting the new transcript
                // with old text.
                guard self.sessionID == mySession else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if let error {
                    #if DEBUG
                    print("SFSpeech task error: \(error)")
                    #endif
                    self.lastErrorMessage = error.localizedDescription
                    self.stopInternalSession()
                    return
                }
                if result?.isFinal == true {
                    self.stopInternalSession()
                }
            }
        }
    }

    /// Stop recording. Returns whatever transcription the recognizer
    /// produced (which may have arrived partially while recording).
    @discardableResult
    func stopRecording() -> String {
        let final = transcript
        stopInternalSession()
        return final
    }

    private func stopInternalSession() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        // Reset the engine — without this, `SFSpeechRecognizer`'s
        // internal context can leak between sessions and a fresh
        // recording starts off with the previous transcription in
        // memory ("ciao" + new audio → "ciao bello").
        audioEngine.reset()
        request?.endAudio()
        request = nil
        recognitionTask?.finish()
        recognitionTask = nil
        isRecording = false
        audioLevel = 0
        // Clear the transcript so the SwiftUI listener doesn't see
        // a stale "ciao" the next time it reads the property.
        transcript = ""
    }

    // MARK: - Level metering

    /// Rises instantly to a new peak and decays gently, so the level ring
    /// tracks speech onsets sharply without flickering between syllables.
    private func absorb(level: Double) {
        guard isRecording else { return }
        audioLevel = max(level, audioLevel * 0.82)
    }

    /// RMS of the buffer mapped from dBFS onto a 0...1 display range.
    /// -50 dB (a quiet room) reads as 0; -5 dB reads as full.
    private nonisolated static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(count))
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(Double(rms))
        let floorDB = -50.0
        let ceilingDB = -5.0
        return min(1, max(0, (decibels - floorDB) / (ceilingDB - floorDB)))
    }
}
