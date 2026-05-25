import Foundation
import SwiftData

enum ReviewRating: Int, Codable, CaseIterable, Identifiable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    var isCorrect: Bool {
        self != .again
    }
}

@Model
final class ReviewLog {
    var wordID: String
    var reviewedAt: Date
    var ratingRaw: Int
    var intervalBeforeDays: Int
    var intervalAfterDays: Int

    init(
        wordID: String,
        reviewedAt: Date,
        rating: ReviewRating,
        intervalBeforeDays: Int,
        intervalAfterDays: Int
    ) {
        self.wordID = wordID
        self.reviewedAt = reviewedAt
        self.ratingRaw = rating.rawValue
        self.intervalBeforeDays = intervalBeforeDays
        self.intervalAfterDays = intervalAfterDays
    }

    var rating: ReviewRating {
        ReviewRating(rawValue: ratingRaw) ?? .good
    }
}
