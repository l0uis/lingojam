import Foundation
import CryptoKit
@preconcurrency import AVFoundation

enum TTSError: Error {
    case noProxyURL
    case badResponse(status: Int)
    case rateLimited
    case network(Error)
    case cancelled
}

/// Fetches synthesized audio from the walrus proxy. Caches MP3 bytes on
/// disk keyed by the SHA-256 of (text + voice + instructions + model)
/// so repeated phrases (openers, closers, nudges) never re-bill OpenAI.
@MainActor
final class OpenAITTSClient {
    static let shared = OpenAITTSClient()

    private let session: URLSession
    private let cache: AudioCache

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.cache = AudioCache()
    }

    /// Fetch (or load from cache) the MP3 audio for `text` rendered with
    /// `voice` and optional natural-language `instructions`. Throws if
    /// the proxy URL isn't configured or the request fails.
    func fetchAudio(
        text: String,
        voice: String = "onyx",
        instructions: String? = nil,
        model: String = "gpt-4o-mini-tts"
    ) async throws -> Data {
        let cacheKey = Self.cacheKey(text: text, voice: voice, instructions: instructions, model: model)
        if let cached = cache.read(key: cacheKey) {
            return cached
        }

        guard let endpoint = URL(string: WalrusProxyConfig.proxyURL)?
                .appendingPathComponent("/v1/walrus/tts") else {
            throw TTSError.noProxyURL
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(DeviceKeyManager.deviceID(), forHTTPHeaderField: "X-Walrus-Device-ID")
        req.setValue(Self.bundleID, forHTTPHeaderField: "X-Walrus-Bundle-ID")

        var body: [String: Any] = [
            "text": text,
            "voice": voice,
            "model": model,
        ]
        if let instructions { body["instructions"] = instructions }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TTSError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.badResponse(status: -1)
        }
        if http.statusCode == 429 {
            throw TTSError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.badResponse(status: http.statusCode)
        }

        cache.write(key: cacheKey, data: data)
        return data
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown.bundle"
    }

    private static func cacheKey(
        text: String,
        voice: String,
        instructions: String?,
        model: String
    ) -> String {
        let payload = "\(model)|\(voice)|\(instructions ?? "")|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Disk cache

/// On-disk MP3 cache. Lives in Caches/walrus-tts and is evicted by the
/// OS under memory pressure. No explicit size cap — at ~20 KB per chat
/// utterance it'd take thousands of entries to matter.
private final class AudioCache {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent("walrus-tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func read(key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func write(key: String, data: Data) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).mp3")
    }
}

// MARK: - Audio player

/// Tiny AVAudioPlayer wrapper used to play OpenAI MP3 audio. Replaces
/// the previous utterance when a new one starts, mirroring
/// `AVSpeechSynthesizer.stopSpeaking(at: .immediate)` behavior.
///
/// `playAndWait` is the variant the voice-call UI uses: it suspends until
/// the clip actually finishes, which is what keeps one speech bubble per
/// sentence in step with Walter's voice.
@MainActor
final class WalrusAudioPlayer: NSObject {
    static let shared = WalrusAudioPlayer()

    private var player: AVAudioPlayer?
    /// Resumed exactly once per `playAndWait` — on natural end, on
    /// interruption by a newer clip, or by the watchdog. Always route
    /// resumes through `finishPlayback()` so that stays true.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// Backstop timer. `AVAudioPlayer`'s delegate callback can be lost if
    /// the audio session is yanked out from under us (a phone call, the
    /// mic taking over); without this the caller would hang forever
    /// mid-conversation.
    private var watchdog: Task<Void, Never>?

    private override init() { super.init() }

    func play(_ data: Data) {
        _ = start(data)
    }

    /// Play `data` and suspend until playback ends. Returns immediately if
    /// the clip can't be decoded, so a bad payload never stalls a turn.
    func playAndWait(_ data: Data) async {
        guard let duration = start(data) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // `start` stopped any previous clip (resuming its continuation),
            // and we haven't suspended since, so nothing is outstanding here.
            finishContinuation = cont
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((duration + 1.0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishPlayback()
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        finishPlayback()
    }

    /// Starts playback and returns the clip's wall-clock duration, or nil
    /// if the data couldn't be decoded.
    @discardableResult
    private func start(_ data: Data) -> Double? {
        stop()
        do {
            // Set the audio session so playback goes to speaker even on silent mode.
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            // Match the slow-grumpy delivery of the tuned Apple TTS so
            // OpenAI's voice doesn't suddenly sound chipper.
            player.enableRate = true
            player.rate = 0.95
            player.prepareToPlay()
            player.play()
            self.player = player
            // Playing below 1.0 rate stretches the clip — the watchdog has
            // to budget for the real elapsed time, not the encoded length.
            return player.duration / Double(player.rate)
        } catch {
            self.player = nil
            return nil
        }
    }

    private func finishPlayback() {
        watchdog?.cancel()
        watchdog = nil
        let cont = finishContinuation
        finishContinuation = nil
        cont?.resume()
    }
}

extension WalrusAudioPlayer: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        guard player === self.player else { return }
        self.player = nil
        finishPlayback()
    }
}
