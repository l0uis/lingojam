import Foundation

enum EnrichmentClientError: Error {
    case noProxyURL
    case badResponse(status: Int)
    case rateLimited
    case decoding
    case network(Error)
}

/// Fetches an accurate vocabulary entry (lemma, part of speech, definition,
/// example sentence + translation) from the walrus proxy, which runs the
/// request through Claude server-side. Used in preference to the on-device
/// model so vocabulary never gets a hallucinated definition or a made-up
/// example word. See `tools/walrus-proxy/src/index.ts` (`/v1/walrus/enrich`).
@MainActor
final class WalrusEnrichmentClient {
    static let shared = WalrusEnrichmentClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    struct Entry: Decodable {
        var lemma: String
        var partOfSpeech: String
        var definition: String
        var exampleSentence: String
        var exampleTranslation: String
    }

    func enrich(
        word: String,
        targetLanguageName: String,
        nativeLanguageName: String
    ) async throws -> Entry {
        guard let endpoint = URL(string: WalrusProxyConfig.proxyURL)?
                .appendingPathComponent("/v1/walrus/enrich") else {
            throw EnrichmentClientError.noProxyURL
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(DeviceKeyManager.deviceID(), forHTTPHeaderField: "X-Walrus-Device-ID")
        req.setValue(Self.bundleID, forHTTPHeaderField: "X-Walrus-Bundle-ID")

        let body: [String: Any] = [
            "word": word,
            "targetLanguage": targetLanguageName,
            "nativeLanguage": nativeLanguageName,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw EnrichmentClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EnrichmentClientError.badResponse(status: -1)
        }
        if http.statusCode == 429 {
            throw EnrichmentClientError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EnrichmentClientError.badResponse(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw EnrichmentClientError.decoding
        }
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown.bundle"
    }
}
