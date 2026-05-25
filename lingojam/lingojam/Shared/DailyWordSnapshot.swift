import Foundation

struct DailyWordSnapshot: Codable, Equatable {
    let wordID: String
    let lemma: String
    let partOfSpeech: String
    let definition: String
    let exampleSentence: String
    let exampleTranslation: String?
    let isDueNow: Bool
    let dueDate: Date?
    let computedAt: Date

    static let storageKey = "dailyWordSnapshot.v1"

    static func load(from defaults: UserDefaults? = AppGroup.sharedDefaults) -> DailyWordSnapshot? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder.snapshot.decode(DailyWordSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults? = AppGroup.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder.snapshot.encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private extension JSONEncoder {
    static let snapshot: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let snapshot: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
