import Foundation
import Observation

/// Remembers that Pro just ran out — a trial that didn't convert, or a
/// subscription that wasn't renewed — so the next launch can show the
/// "trial ended" paywall once instead of letting the moment pass silently.
/// Recorded by `Entitlements` when a fresh store reading flips from Pro to
/// not-Pro; cleared once shown, or if they come back.
@Observable
@MainActor
final class ProLapse {
    static let shared = ProLapse()

    private static let pendingKey = "wordrus.entitlements.lapsePending"
    private static let wasTrialKey = "wordrus.entitlements.lapseWasTrial"

    /// A lapse the learner hasn't been shown yet.
    private(set) var isPending: Bool
    /// Whether what ran out was the free trial (vs. a paid year).
    private(set) var wasTrial: Bool

    private init() {
        isPending = UserDefaults.standard.bool(forKey: Self.pendingKey)
        wasTrial = UserDefaults.standard.bool(forKey: Self.wasTrialKey)
    }

    func record(wasTrial: Bool) {
        self.wasTrial = wasTrial
        isPending = true
        UserDefaults.standard.set(wasTrial, forKey: Self.wasTrialKey)
        UserDefaults.standard.set(true, forKey: Self.pendingKey)
    }

    /// Shown, or no longer relevant because they're Pro again.
    func clear() {
        guard isPending else { return }
        isPending = false
        UserDefaults.standard.set(false, forKey: Self.pendingKey)
    }
}

/// What a lapsed learner built up while they had Pro, for the "trial ended"
/// paywall. Counts of zero fall back to the generic benefit copy.
struct LapseSummary: Identifiable {
    let id = UUID()
    let wasTrial: Bool
    let storyCount: Int
    let customWordCount: Int
    let outgoingCallCount: Int
}
