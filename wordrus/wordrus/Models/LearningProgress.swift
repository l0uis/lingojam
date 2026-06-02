import Foundation
import SwiftData

enum LearningState: String, Codable {
    case new
    case learning
    case review
    case known
}

@Model
final class LearningProgress {
    @Attribute(.unique) var wordID: String
    var stateRaw: String
    var easeFactor: Double
    var intervalDays: Int
    var repetitions: Int
    var lapses: Int
    var dueDate: Date
    var lastReviewedAt: Date?

    init(
        wordID: String,
        state: LearningState = .new,
        easeFactor: Double = 2.5,
        intervalDays: Int = 0,
        repetitions: Int = 0,
        lapses: Int = 0,
        dueDate: Date = .now,
        lastReviewedAt: Date? = nil
    ) {
        self.wordID = wordID
        self.stateRaw = state.rawValue
        self.easeFactor = easeFactor
        self.intervalDays = intervalDays
        self.repetitions = repetitions
        self.lapses = lapses
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
    }

    var state: LearningState {
        get { LearningState(rawValue: stateRaw) ?? .new }
        set { stateRaw = newValue.rawValue }
    }
}
