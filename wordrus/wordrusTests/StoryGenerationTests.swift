import Foundation
import Testing
@testable import wordrus

@MainActor
struct StoryGenerationTests {
    private let request = StoryRequest(
        language: .spanish,
        nativeLanguageCode: "en",
        level: .a2,
        knownWords: ["ir", "playa", "comer"],
        newWords: ["pez", "salir"],
        topic: "Animals",
        previousEpisodeSummary: "Dr Tusk found a note."
    )

    // MARK: Claude brain request

    @Test func claudeRequestCarriesWordsLevelAndLength() throws {
        let body = ClaudeStoryBrain.body(for: request, repair: nil)
        #expect(body.language == "Spanish")
        #expect(body.nativeLanguage == "English")
        #expect(body.level == "A2")
        #expect(body.knownWords == ["ir", "playa", "comer"])
        #expect(body.newWords == ["pez", "salir"])
        #expect(body.minWords == StoryLength.for(.a2).words.lowerBound)
        #expect(body.maxWords == StoryLength.for(.a2).words.upperBound)
        #expect(body.maxSentenceWords == StoryLength.for(.a2).maxSentenceWords)
        #expect(body.previousEpisode == "Dr Tusk found a note.")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(json?["repair"] == nil)
    }

    @Test func repairSendsTheDraftInTheToolSchema() throws {
        let draft = GeneratedStory(
            title: "T", story: "S",
            newWordSentences: [StoryWordSentence(word: "pez", sentence: "Un pez.")],
            questions: [StoryQuestion(question: "Q", options: ["a", "b", "c"], answerIndex: 1)],
            episodeSummary: "E"
        )
        let body = ClaudeStoryBrain.body(
            for: request,
            repair: .init(draft: draft, unknownWords: ["manzana"], missingNewWords: ["salir"])
        )
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let repair = try #require(json["repair"] as? [String: Any])
        #expect(repair["unknownWords"] as? [String] == ["manzana"])
        #expect(repair["missingNewWords"] as? [String] == ["salir"])
        let sent = try #require(repair["draft"] as? [String: Any])
        // Snake case, exactly like the worker's `submit_story` tool input.
        #expect(Set(sent.keys) == ["title", "story", "new_word_sentences", "questions", "episode_summary"])
        let question = try #require((sent["questions"] as? [[String: Any]])?.first)
        #expect(question["answer_index"] as? Int == 1)
    }

    // MARK: Apple brain prompt

    @Test func onDevicePromptStatesTheRulesAndCapsTheWordList() {
        var big = request
        big.knownWords = (1...300).map { StoryWord(lemma: "w\($0)") }
        let prompt = StoryPrompt.instructions(for: big, knownWordLimit: 150)
        #expect(prompt.contains("Use ONLY words from ALLOWED_WORDS"))
        #expect(prompt.contains("Use EVERY word in NEW_WORDS at least twice"))
        #expect(prompt.contains("NEW_WORDS: pez, salir"))
        #expect(prompt.contains("w150"))
        #expect(!prompt.contains("w151"))
        #expect(prompt.contains("Previous episode: Dr Tusk found a note. Topic: Animals."))
    }

    @Test func repairPromptNamesTheRejectedWords() {
        let prompt = StoryPrompt.repair(unknownLemmas: ["manzana", "uva"], missingNewWords: ["salir"])
        #expect(prompt.contains("not allowed: manzana, uva."))
        #expect(prompt.contains("at least twice: salir."))
        #expect(prompt.contains("same plot"))
    }

    @Test func claudeLeadsTheChainAndTheMockIsLastInDebug() {
        let names = StoryBrainFactory.makeChain().map(\.brainName)
        #expect(names.first == "claude")
        #expect(names.last == "mock")
    }

    // MARK: Notification timing

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    /// Saturday 3 Oct 2026 at `hour:minute`, Madrid time.
    private func saturday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute))!
    }

    private func slot(now: Date, days: Set<Int> = Set(1...7), reminders: [Date] = []) -> Date? {
        StoryScheduler.notificationDate(
            now: now,
            start: DateComponents(hour: 9, minute: 0),
            end: DateComponents(hour: 20, minute: 0),
            daysOfWeek: days,
            reminderDates: reminders,
            calendar: calendar
        )
    }

    @Test func storyNotificationWaitsForTheReminderWindow() {
        #expect(slot(now: saturday(6, 30)) == saturday(9))
        #expect(slot(now: saturday(14, 10)) == saturday(14, 11))
        #expect(slot(now: saturday(21)) == nil)
    }

    @Test func storyNotificationKeepsClearOfWordReminders() {
        // Reminder at 9:20 blocks 8:35–10:05 on the 15-minute grid from 9:00.
        let slot = slot(now: saturday(7), reminders: [saturday(9, 20)])
        #expect(slot == saturday(10, 15))
        // Reminders covering the whole window leave no slot.
        let wall = stride(from: 9, through: 20, by: 1).map { saturday($0) }
        #expect(self.slot(now: saturday(7), reminders: wall) == nil)
    }

    @Test func storyNotificationRespectsNotificationDays() {
        // Saturday is weekday 7.
        #expect(slot(now: saturday(7), days: [2, 3, 4, 5, 6]) == nil)
        #expect(slot(now: saturday(7), days: [7]) == saturday(9))
    }

    // MARK: Phone tab badge

    private func story(_ language: TargetLanguage, opened: Bool) -> DailyStory {
        let story = DailyStory(
            dayKey: "d", language: language, level: .a1, topic: "t",
            story: GeneratedStory(title: "T", story: "S", newWordSentences: [], questions: [], episodeSummary: ""),
            newWords: [], extraWords: [],
            report: StoryCoverageReport(coverage: 1, contentTokenCount: 0, unknownTokenCount: 0, unknownLemmas: [], newWordUses: [:], wordCount: 0, failures: []),
            brain: "mock", attempts: 1
        )
        if opened { story.openedAt = .now }
        return story
    }

    @Test func badgeCountsUnreadStoriesInTheActiveLanguageForPro() {
        let stories = [story(.spanish, opened: false), story(.spanish, opened: true), story(.spanish, opened: false), story(.french, opened: false)]
        #expect(StoryBadge.unreadCount(stories: stories, languageRaw: "spanish", isPro: true) == 2)
        #expect(StoryBadge.unreadCount(stories: stories, languageRaw: "french", isPro: true) == 1)
        #expect(StoryBadge.unreadCount(stories: stories, languageRaw: "spanish", isPro: false) == 0)
        #expect(StoryBadge.unreadCount(stories: [], languageRaw: "spanish", isPro: true) == 0)
    }

    // MARK: Recents

    @Test func recentsInterleaveCallsAndStoriesNewestFirst() {
        let early = ChatSession(startedAt: Date(timeIntervalSince1970: 1_000), levelAtStart: "A1")
        let late = ChatSession(startedAt: Date(timeIntervalSince1970: 3_000), levelAtStart: "A1")
        let story = DailyStory(
            dayKey: "d", createdAt: Date(timeIntervalSince1970: 2_000), language: .spanish, level: .a1, topic: "t",
            story: GeneratedStory(title: "T", story: "S", newWordSentences: [], questions: [], episodeSummary: ""),
            newWords: [], extraWords: [],
            report: StoryCoverageReport(coverage: 1, contentTokenCount: 0, unknownTokenCount: 0, unknownLemmas: [], newWordUses: [:], wordCount: 0, failures: []),
            brain: "mock", attempts: 1
        )
        let ids = RecentItem.merged(calls: [early, late], stories: [story]).map(\.id)
        #expect(ids == ["call-\(late.id.uuidString)", "story-\(story.id.uuidString)", "call-\(early.id.uuidString)"])
    }
}
