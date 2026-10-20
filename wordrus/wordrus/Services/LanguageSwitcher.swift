import Foundation
import SwiftData

/// The one way to move the learner to another target language after
/// onboarding. `SeedDataLoader.switchLanguage` swaps the data (words, decks,
/// per-language level and daily-set state); this also brings along
/// everything that would otherwise keep talking about the old language until
/// the next launch — Dr Tusk's scheduled calls, today's story, the Live
/// Activity — and records the switch.
@MainActor
enum LanguageSwitcher {

    static func switchLanguage(to language: TargetLanguage, level: CEFRLevel? = nil, context: ModelContext) {
        let previous = OnboardingStore.targetLanguage
        guard previous != language else { return }

        // Settle calls that already rang before their language changes under
        // them, then swap.
        MissedCallReconciler.reconcileIfNeeded(context)
        SeedDataLoader.switchLanguage(to: language, level: level, context: context)
        LiveActivityService.refresh()

        // Pending calls have the old language's name baked into their text.
        if OnboardingStore.hasCompleted {
            NotificationService.scheduleWalrusCalls()
        }

        Analytics.capture(.languageSwitched, [
            "from": previous?.rawValue ?? "none",
            "to": language.rawValue,
            "level": OnboardingStore.cefrLevel.rawValue,
            "first_time": level != nil
        ])

        // Pro: today's story in the new language, waiting in the Phone tab.
        // No notification — they're in the app and just asked for this.
        Task { await StoryScheduler.prepareTodayStory(context: context, announce: false) }
    }

    /// What the switch sheet shows about a language: where the learner is
    /// with it, or nil if they've never studied it.
    struct Summary {
        let level: CEFRLevel
        let knownWords: Int
        let stories: Int
    }

    static func summary(for language: TargetLanguage, context: ModelContext) -> Summary? {
        let isActive = (OnboardingStore.targetLanguage ?? .spanish) == language
        guard let level = isActive ? OnboardingStore.cefrLevel : OnboardingStore.storedLevel(for: language) else {
            return nil
        }
        // Progress rows outlive a switch (their word ids carry the language),
        // so they count for languages whose words aren't loaded right now.
        let code = language.languageCode
        let progress = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let known = progress.filter { $0.state == .known && languageCode(ofWordID: $0.wordID) == code }.count
        let stories = DailyStoryService.history(context: context, language: language).count
        return Summary(level: level, knownWords: known, stories: stories)
    }

    /// Mirrors `VocabularyWord.languageCode`: "es-0001" → "es",
    /// "custom-es-…" → "es".
    private static func languageCode(ofWordID id: String) -> String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        if id.hasPrefix("custom-") {
            return parts.count >= 2 ? String(parts[1]) : ""
        }
        return parts.first.map(String.init) ?? ""
    }
}
