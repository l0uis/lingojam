import Foundation

struct SRSResult: Equatable {
    let state: LearningState
    let easeFactor: Double
    let intervalDays: Int
    let repetitions: Int
    let lapses: Int
    let dueDate: Date
    let lastReviewedAt: Date
}

enum SRSScheduler {
    static let minimumEase: Double = 1.3
    static let initialEase: Double = 2.5

    static func next(
        progress: LearningProgress,
        rating: ReviewRating,
        now: Date = .now
    ) -> SRSResult {
        // First-encounter "I know it" retires the word from review rotation.
        if rating == .good, progress.lastReviewedAt == nil {
            return SRSResult(
                state: .known,
                easeFactor: progress.easeFactor,
                intervalDays: 0,
                repetitions: 1,
                lapses: progress.lapses,
                dueDate: .distantFuture,
                lastReviewedAt: now
            )
        }

        let priorEase = progress.easeFactor
        var ease = priorEase
        var repetitions = progress.repetitions
        var lapses = progress.lapses
        var intervalDays: Int
        var state: LearningState

        switch rating {
        case .again:
            ease = max(minimumEase, priorEase - 0.2)
            repetitions = 0
            lapses += 1
            intervalDays = 1
            state = .learning
        case .hard:
            ease = max(minimumEase, priorEase - 0.15)
            repetitions += 1
            intervalDays = nextInterval(
                rating: .hard,
                repetitions: repetitions,
                previousInterval: progress.intervalDays,
                ease: priorEase
            )
            state = repetitions >= 2 ? .review : .learning
        case .good:
            repetitions += 1
            intervalDays = nextInterval(
                rating: .good,
                repetitions: repetitions,
                previousInterval: progress.intervalDays,
                ease: priorEase
            )
            state = repetitions >= 2 ? .review : .learning
        case .easy:
            ease = priorEase + 0.15
            repetitions += 1
            intervalDays = nextInterval(
                rating: .easy,
                repetitions: repetitions,
                previousInterval: progress.intervalDays,
                ease: priorEase
            )
            state = .review
        }

        let due = Calendar.current.date(byAdding: .day, value: intervalDays, to: now) ?? now
        return SRSResult(
            state: state,
            easeFactor: ease,
            intervalDays: intervalDays,
            repetitions: repetitions,
            lapses: lapses,
            dueDate: due,
            lastReviewedAt: now
        )
    }

    private static func nextInterval(
        rating: ReviewRating,
        repetitions: Int,
        previousInterval: Int,
        ease: Double
    ) -> Int {
        if repetitions == 1 {
            return rating == .easy ? 4 : 1
        }
        if repetitions == 2 {
            switch rating {
            case .hard: return 4
            case .good: return 6
            case .easy: return 10
            case .again: return 1
            }
        }
        let base = Double(max(previousInterval, 1))
        let multiplier: Double = switch rating {
        case .hard: 1.2
        case .good: ease
        case .easy: ease * 1.3
        case .again: 1.0
        }
        return max(1, Int(round(base * multiplier)))
    }
}
