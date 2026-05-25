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
@MainActor
final class WalrusAudioPlayer: NSObject {
    static let shared = WalrusAudioPlayer()

    private var player: AVAudioPlayer?

    private override init() { super.init() }

    func play(_ data: Data) {
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
        } catch {
            self.player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

extension WalrusAudioPlayer: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        if player === self.player { self.player = nil }
    }
}
