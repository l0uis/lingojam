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
}

enum DeckConstants {
    static let commonSlug = "common"
    static let allSlug = "__all"
    static let selectedDeckDefaultsKey = "selectedDeckSlug"
    static let selectedCEFRLevelDefaultsKey = "selectedCEFRLevel"
    static let allLevelsValue = "__all"
    static let cefrLevels: [String] = ["A1", "A2", "B1", "B2", "C1", "C2"]
    static let defaultCEFRLevel = "A1"
}
