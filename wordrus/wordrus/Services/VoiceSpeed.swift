import Foundation
import SwiftUI

/// How fast Dr Tusk talks — word cards, calls and stories alike. A Pro
/// perk: the choice is remembered for everyone, but only applied while Pro
/// is active, so a lapsed subscription quietly falls back to normal speed
/// and picks the old choice back up on renewal.
enum VoiceSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast
    case faster

    static let defaultsKey = "wordrus.voiceSpeed"

    var id: String { rawValue }

    /// Multiplier on each voice's own tuned rate (the grumpy 0.95 call
    /// voice, the story narrator, the Apple fallback).
    var multiplier: Float {
        switch self {
        case .slow: return 0.8
        case .normal: return 1.0
        case .fast: return 1.2
        case .faster: return 1.4
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .faster: return "Faster"
        }
    }

    /// The learner's saved choice, whether or not it's currently applied.
    static var stored: VoiceSpeed {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(VoiceSpeed.init(rawValue:)) ?? .normal
    }

    /// The speed playback should use right now.
    @MainActor
    static var effective: VoiceSpeed {
        Entitlements.shared.isPro ? stored : .normal
    }
}
