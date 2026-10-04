import Foundation

/// Writes stories with Claude through the walrus proxy (`/v1/walrus/story`).
/// The prompt and the `submit_story` tool live in the worker, like the call
/// prompt does; the app sends the words and checks what comes back.
struct ClaudeStoryBrain: StoryGenerating {
    let brainName = "claude"

    /// A story plus a possible Sonnet fallback on the worker takes longer
    /// than a call turn.
    private static let timeout: TimeInterval = 45

    func generateStory(_ request: StoryRequest) async throws -> GeneratedStory {
        try await send(Self.body(for: request, repair: nil))
    }

    func repairStory(
        _ story: GeneratedStory,
        request: StoryRequest,
        unknownLemmas: [String],
        missingNewWords: [String]
    ) async throws -> GeneratedStory {
        try await send(Self.body(
            for: request,
            repair: Repair(draft: story, unknownWords: unknownLemmas, missingNewWords: missingNewWords)
        ))
    }

    // MARK: - Request

    struct Repair: Encodable {
        let draft: GeneratedStory
        let unknownWords: [String]
        let missingNewWords: [String]
    }

    struct Body: Encodable {
        let language: String
        let nativeLanguage: String
        let level: String
        let knownWords: [String]
        let newWords: [String]
        let topic: String
        let previousEpisode: String?
        let minWords: Int
        let maxWords: Int
        let maxSentenceWords: Int
        let repair: Repair?
    }

    static func body(for request: StoryRequest, repair: Repair?) -> Body {
        Body(
            language: request.language.englishName,
            nativeLanguage: Locale(identifier: "en").localizedString(forLanguageCode: request.nativeLanguageCode) ?? "English",
            level: request.level.rawValue,
            knownWords: request.knownWords.map(\.lemma),
            newWords: request.newWords.map(\.lemma),
            topic: request.topic,
            previousEpisode: request.previousEpisodeSummary,
            minWords: request.length.words.lowerBound,
            maxWords: request.length.words.upperBound,
            maxSentenceWords: request.length.maxSentenceWords,
            repair: repair
        )
    }

    private func send(_ body: Body) async throws -> GeneratedStory {
        guard let endpoint = URL(string: WalrusProxyConfig.proxyURL)?
            .appendingPathComponent("/v1/walrus/story") else { throw StoryGenerationError.unavailable }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceKeyManager.deviceID(), forHTTPHeaderField: "X-Walrus-Device-ID")
        request.setValue(Bundle.main.bundleIdentifier ?? "unknown.bundle", forHTTPHeaderField: "X-Walrus-Bundle-ID")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            #if DEBUG
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[ClaudeStoryBrain] proxy returned \(status): \(String(decoding: data, as: UTF8.self).prefix(200))")
            #endif
            throw StoryGenerationError.unavailable
        }
        return try JSONDecoder().decode(GeneratedStory.self, from: data)
    }
}
