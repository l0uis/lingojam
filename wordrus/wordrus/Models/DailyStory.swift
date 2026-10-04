import Foundation
import SwiftData

/// One of Dr Tusk's daily stories: generated once per day per language, built
/// from the learner's own words and checked on device by
/// `StoryVocabularyChecker` before it's saved.
///
/// Lists are stored as JSON strings, like `VocabularyWord.deckSlugsJSON` and
/// `ChatSession.targetWordIDsJSON`, so the schema stays flat and lightweight
/// migration keeps working.
@Model
final class DailyStory {
    @Attribute(.unique) var id: UUID
    /// `DailySetConfig.dayKey` of the day the story belongs to.
    var dayKey: String
    var createdAt: Date
    /// `TargetLanguage.rawValue`.
    var languageRaw: String
    /// CEFR raw value (A1…C2) the story was written for.
    var levelRaw: String
    var topic: String

    var title: String
    var text: String
    /// Lemmas the story was asked to teach (each used at least twice).
    var newWordsJSON: String
    /// Words the vocabulary check couldn't place in the learner's vocabulary
    /// but accepted anyway (at most a couple). Highlighted as new alongside
    /// `newWords`.
    var extraWordsJSON: String
    /// `[StoryWordSentence]`: one sentence per new word that hints at its meaning.
    var newWordSentencesJSON: String
    /// `[StoryQuestion]`.
    var questionsJSON: String
    /// One or two sentences carried into tomorrow's prompt so the series continues.
    var episodeSummary: String

    /// Known content tokens / content tokens, from the vocabulary check.
    var coverage: Double
    /// Full `StoryCoverageReport` as JSON.
    var coverageReportJSON: String
    /// Which brain wrote it ("claude", "apple", "mock").
    var brainRaw: String
    /// Generation + repair calls it took to get an acceptable story.
    var attempts: Int

    var openedAt: Date?
    /// Set when the learner reaches the end screen.
    var completedAt: Date?
    var quizCorrect: Int?
    var quizTotal: Int?
    /// File name of the cached narration in the story audio cache.
    var audioFileName: String?

    init(
        id: UUID = UUID(),
        dayKey: String,
        createdAt: Date = .now,
        language: TargetLanguage,
        level: CEFRLevel,
        topic: String,
        story: GeneratedStory,
        newWords: [String],
        extraWords: [String],
        report: StoryCoverageReport,
        brain: String,
        attempts: Int
    ) {
        self.id = id
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.languageRaw = language.rawValue
        self.levelRaw = level.rawValue
        self.topic = topic
        self.title = story.title
        self.text = story.story
        self.newWordsJSON = Self.encode(newWords)
        self.extraWordsJSON = Self.encode(extraWords)
        self.newWordSentencesJSON = Self.encode(story.newWordSentences)
        self.questionsJSON = Self.encode(story.questions)
        self.episodeSummary = story.episodeSummary
        self.coverage = report.coverage
        self.coverageReportJSON = Self.encode(report)
        self.brainRaw = brain
        self.attempts = attempts
    }

    var language: TargetLanguage? { TargetLanguage(rawValue: languageRaw) }
    var level: CEFRLevel? { CEFRLevel(rawValue: levelRaw) }

    var newWords: [String] { Self.decode(newWordsJSON) ?? [] }
    var extraWords: [String] { Self.decode(extraWordsJSON) ?? [] }
    /// Everything the story screen highlights as new.
    var highlightedWords: [String] { newWords + extraWords }
    var newWordSentences: [StoryWordSentence] { Self.decode(newWordSentencesJSON) ?? [] }
    var questions: [StoryQuestion] { Self.decode(questionsJSON) ?? [] }
    var coverageReport: StoryCoverageReport? { Self.decode(coverageReportJSON) }

    /// Unopened stories show as "missed" in the Phone tab, like missed calls.
    var isOpened: Bool { openedAt != nil }
    var isCompleted: Bool { completedAt != nil }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ json: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
