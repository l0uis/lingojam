import Foundation
import Observation

/// The one-off introduction to Dr Tusk's stories. When a learner's very
/// first story is written — usually minutes after their trial starts —
/// `StoryScheduler` hands it here and `RootView` presents `FirstStorySheet`
/// at the next quiet moment. Shown once per install.
@Observable
@MainActor
final class FirstStoryIntro {
    static let shared = FirstStoryIntro()

    private static let shownKey = "wordrus.story.firstIntroShown"

    /// The story waiting to be introduced, or nil.
    var story: DailyStory?

    private init() {}

    func offer(_ story: DailyStory) {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        self.story = story
    }

    func markShown() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }
}
