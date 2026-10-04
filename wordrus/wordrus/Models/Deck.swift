import Foundation
import SwiftData

@Model
final class Deck {
    @Attribute(.unique) var slug: String
    var displayName: String
    var deckDescription: String
    var iconSystemName: String
    var sortOrder: Int

    init(
        slug: String,
        displayName: String,
        deckDescription: String = "",
        iconSystemName: String = "square.stack",
        sortOrder: Int = 0
    ) {
        self.slug = slug
        self.displayName = displayName
        self.deckDescription = deckDescription
        self.iconSystemName = iconSystemName
        self.sortOrder = sortOrder
    }

    /// Name to show in the UI. `displayName` comes from the seed JSON in
    /// English; topic decks map onto `LearningTopic`, whose titles are in the
    /// String Catalog.
    var localizedName: String {
        if slug == DeckConstants.myWordsSlug { return String(localized: "My Words") }
        return LearningTopic(rawValue: slug)?.title ?? displayName
    }
}

enum DeckConstants {
    static let commonSlug = "common"
    static let allSlug = "__all"
    /// Synthetic deck for the user's own added words. Not seeded from JSON —
    /// JamView injects it into the theme rotation when custom words exist, and
    /// new custom words are tagged with it.
    static let myWordsSlug = "__mywords"
    static let selectedDeckDefaultsKey = "selectedDeckSlug"
}
