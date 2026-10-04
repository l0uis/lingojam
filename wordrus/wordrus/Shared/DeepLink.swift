import Foundation
import Observation

/// App-wide reactive channel for "show me this specific word" deep links,
/// raised by tapping a Home Screen widget, a Live Activity, or a word
/// reminder notification (all of which carry a `VocabularyWord.id`).
///
/// `RootView` observes `pendingWordID` and, whenever it becomes non-nil,
/// presents the word sheet over whatever the user was doing — on any tab,
/// at cold launch or when foregrounding. Living at the app root (rather than
/// inside a single tab) is what makes the deep-linked word *always* appear.
@Observable
@MainActor
final class DeepLinkCoordinator {
    static let shared = DeepLinkCoordinator()

    /// The id of a `VocabularyWord` to surface, or nil when nothing is
    /// pending. Set from any launch/foreground entry point; `RootView` clears
    /// it as soon as it has presented (or failed to find) the word, so the
    /// same tap never re-presents. In-memory only — nothing persists across
    /// launches, so a stale link can't resurface days later.
    var pendingWordID: String?

    /// The word the Deck's card stack is currently showing, or nil when no
    /// readable card is on screen (the intro, empty and completion states show
    /// none, and so does any other tab). `RootView` drops a deep link to this
    /// word rather than presenting the sheet: the card is already in front of
    /// the user, and a sheet over it would just duplicate it. Kept in sync by
    /// `JamView`; in-memory only.
    var visibleWordID: String?

    /// The id of a `DailyStory` to open, raised by tapping its "new story"
    /// notification. `RootView` clears it once presented.
    var pendingStoryID: UUID?

    private init() {}

    /// Request that the given word be shown. Safe to call from any deep-link
    /// entry point; `RootView` decides whether the word still needs a sheet
    /// (see `visibleWordID`) and clears the request either way.
    func request(wordID: String) {
        guard !wordID.isEmpty else { return }
        pendingWordID = wordID
    }

    func request(storyID: UUID) {
        pendingStoryID = storyID
    }
}
