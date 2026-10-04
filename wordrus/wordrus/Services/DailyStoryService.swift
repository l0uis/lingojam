import Foundation
import SwiftData

/// How many stories a learner may get. Stories are a Pro feature: Pro is
/// unlimited, free gets `freeStoriesPerWeek` (none today — raise it to give
/// free users a taste). Checked before anything is generated, so a free
/// user never costs a Claude call.
nonisolated enum StoryQuota: Equatable, Sendable {
    case unlimited
    case perWeek(Int)

    static let freeStoriesPerWeek = 0

    static func forUser(isPro: Bool) -> StoryQuota {
        isPro ? .unlimited : .perWeek(freeStoriesPerWeek)
    }

    func allowsAnother(generatedInLastWeek count: Int) -> Bool {
        switch self {
        case .unlimited: true
        case .perWeek(let limit): count < limit
        }
    }
}

/// Owns `DailyStory` rows: one per day per language, generated on demand (and
/// later ahead of time in the background), with a short episode history so
/// each story continues yesterday's.
@MainActor
enum DailyStoryService {
    /// Stories kept per language. Only the latest one feeds the next prompt;
    /// the rest are for re-reading and the weekly recap.
    static let historyLimit = 14

    /// Concurrent requests for the same day and store share one generation
    /// (the background refresh and the learner opening the story can
    /// overlap). Tasks hand back the story's id — models aren't Sendable.
    private static var inFlight: [String: Task<UUID, Error>] = [:]

    static func todayStory(context: ModelContext, language: TargetLanguage, now: Date = .now) -> DailyStory? {
        story(context: context, language: language, dayKey: DailySetConfig.dayKey(now))
    }

    static func story(context: ModelContext, language: TargetLanguage, dayKey: String) -> DailyStory? {
        let raw = language.rawValue
        var descriptor = FetchDescriptor<DailyStory>(
            predicate: #Predicate { $0.languageRaw == raw && $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func story(context: ModelContext, id: UUID) -> DailyStory? {
        var descriptor = FetchDescriptor<DailyStory>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Stories for a language, newest first.
    static func history(context: ModelContext, language: TargetLanguage) -> [DailyStory] {
        let raw = language.rawValue
        let descriptor = FetchDescriptor<DailyStory>(
            predicate: #Predicate { $0.languageRaw == raw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The most recent episode summary from a day other than `dayKey`.
    static func previousEpisodeSummary(context: ModelContext, language: TargetLanguage, before dayKey: String) -> String? {
        history(context: context, language: language)
            .first { $0.dayKey != dayKey && !$0.episodeSummary.isEmpty }?
            .episodeSummary
    }

    /// Today's story, generating and saving it first if needed. `brains`
    /// defaults to `StoryBrainFactory.makeChain()`.
    static func ensureTodayStory(
        context: ModelContext,
        language: TargetLanguage,
        now: Date = .now,
        brains: [StoryGenerating]? = nil,
        quota: StoryQuota? = nil
    ) async throws -> DailyStory {
        let dayKey = DailySetConfig.dayKey(now)
        if let existing = story(context: context, language: language, dayKey: dayKey) { return existing }

        let selection = StoryWordSelector.selection(context: context, language: language, now: now)
        let earlier = history(context: context, language: language).filter { $0.dayKey != dayKey }
        let request = StoryRequest(
            language: language,
            nativeLanguageCode: LocaleService.preferredDefinitionLocale,
            level: OnboardingStore.cefrLevel,
            knownWords: selection.knownWords,
            newWords: selection.newWords,
            topic: selection.topic,
            previousEpisodeSummary: previousEpisodeSummary(context: context, language: language, before: dayKey),
            episodeNumber: earlier.count + 1,
            recentTitles: earlier.prefix(5).map(\.title)
        )
        return try await generateAndSave(
            request: request, dayKey: dayKey, context: context,
            brains: brains ?? StoryBrainFactory.makeChain(), quota: quota, now: now
        )
    }

    /// Runs the pipeline for `request` and stores the result as `dayKey`'s
    /// story. Returns the existing story if one appeared in the meantime.
    static func generateAndSave(
        request: StoryRequest,
        dayKey: String,
        context: ModelContext,
        brains: [StoryGenerating],
        quota: StoryQuota? = nil,
        now: Date = .now
    ) async throws -> DailyStory {
        let quota = quota ?? StoryQuota.forUser(isPro: Entitlements.shared.isPro)
        // Per context too: a story generated for one store must never be
        // handed to another (in-memory stores in tests, for instance).
        let key = "\(ObjectIdentifier(context))|\(request.language.rawValue)|\(dayKey)"
        if let running = inFlight[key] {
            let id = try await running.value
            guard let existing = story(context: context, id: id) else { throw StoryGenerationError.unavailable }
            return existing
        }

        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let recentCount = history(context: context, language: request.language).filter { $0.createdAt > weekAgo }.count
        guard quota.allowsAnother(generatedInLastWeek: recentCount) else { throw StoryGenerationError.quotaReached }
        guard let lexicon = StoryLexicon.load(for: request.language) else { throw StoryGenerationError.unavailable }

        let task = Task<UUID, Error> {
            let outcome = try await StoryPipeline(brains: brains, lexicon: lexicon).run(request)
            if let existing = story(context: context, language: request.language, dayKey: dayKey) { return existing.id }
            let story = DailyStory(
                dayKey: dayKey,
                createdAt: now,
                language: request.language,
                level: request.level,
                topic: request.topic,
                story: outcome.story,
                newWords: request.newWords.map(\.lemma),
                extraWords: outcome.extraWords,
                report: outcome.report,
                brain: outcome.brainName,
                attempts: outcome.attempts
            )
            context.insert(story)
            prune(context: context, language: request.language)
            try? context.save()
            StoryScheduler.noteStoryReady(language: request.language, dayKey: dayKey)
            return story.id
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        guard let saved = story(context: context, id: try await task.value) else { throw StoryGenerationError.unavailable }
        return saved
    }

    /// Drops all but the newest `historyLimit` stories for a language,
    /// deleting their cached narration too.
    static func prune(context: ModelContext, language: TargetLanguage) {
        for story in history(context: context, language: language).dropFirst(historyLimit) {
            if let file = story.audioFileName {
                try? FileManager.default.removeItem(at: storyAudioDirectory.appendingPathComponent(file))
            }
            context.delete(story)
        }
    }

    /// Where story narration is cached, one file per story.
    static var storyAudioDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("story-audio", isDirectory: true)
    }
}
