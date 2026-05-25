import Foundation

/// Common European Framework of Reference levels — used to gate Walter's
/// chat difficulty and the user's self-assessed Spanish level.
///
/// `DeckConstants.cefrLevels` lists the raw string values used to tag
/// vocabulary words; this enum mirrors them so the chat feature can reason
/// about ordering, promotion, and display.
enum CEFRLevel: String, CaseIterable, Identifiable, Comparable, Codable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"
    case c2 = "C2"

    var id: String { rawValue }

    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .a1: "Just getting started"
        case .a2: "Basic phrases and everyday questions"
        case .b1: "Short conversations on familiar topics"
        case .b2: "Comfortable in most situations"
        case .c1: "Fluent on complex topics"
        case .c2: "Near-native — anything goes"
        }
    }

    var systemImage: String {
        switch self {
        case .a1: "leaf"
        case .a2: "leaf.fill"
        case .b1: "flame"
        case .b2: "flame.fill"
        case .c1: "bolt"
        case .c2: "bolt.fill"
        }
    }

    var next: CEFRLevel? {
        let all = CEFRLevel.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    var previous: CEFRLevel? {
        let all = CEFRLevel.allCases
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }

    static func < (lhs: CEFRLevel, rhs: CEFRLevel) -> Bool {
        guard let l = CEFRLevel.allCases.firstIndex(of: lhs),
              let r = CEFRLevel.allCases.firstIndex(of: rhs) else { return false }
        return l < r
    }
}
