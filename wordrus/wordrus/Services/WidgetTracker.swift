import Foundation
import WidgetKit

/// Reports Home Screen widgets being added and removed.
///
/// iOS doesn't tell the app when someone adds a widget, so on every return
/// to the foreground we ask WidgetKit what's installed and compare it with
/// what we saw last time. A widget added and removed while the app was
/// never opened goes unseen, and the event lands when the app is next
/// opened, not when the widget was placed.
@MainActor
enum WidgetTracker {

    private static let seenKey = "widgetTracker.seenConfigurations"

    private static var defaults: UserDefaults { .standard }

    /// Call when the app becomes active.
    static func check() {
        Task { @MainActor in
            guard let configurations = try? await WidgetCenter.shared.currentConfigurations() else { return }

            // One entry per placed widget, so two small widgets count twice.
            var current: [String: Int] = [:]
            for configuration in configurations {
                current["\(configuration.kind):\(familyName(configuration.family))", default: 0] += 1
            }

            // First check after installing (or updating to) this build: any
            // widgets already on the Home Screen are reported once, flagged
            // so they can be told apart from fresh additions.
            let isFirstCheck = defaults.dictionary(forKey: seenKey) == nil
            let seen = defaults.dictionary(forKey: seenKey) as? [String: Int] ?? [:]

            for (key, count) in current {
                let added = count - (seen[key] ?? 0)
                for _ in 0..<max(added, 0) {
                    Analytics.capture(.widgetAdded, properties(key, isFirstCheck: isFirstCheck))
                }
            }
            for (key, count) in seen {
                let removed = count - (current[key] ?? 0)
                for _ in 0..<max(removed, 0) {
                    Analytics.capture(.widgetRemoved, properties(key, isFirstCheck: false))
                }
            }

            defaults.set(current, forKey: seenKey)
            Analytics.setHasWidget(!current.isEmpty)
        }
    }

    private static func properties(_ key: String, isFirstCheck: Bool) -> [String: Any] {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        return [
            "widget_kind": parts.first ?? "unknown",
            "family": parts.count > 1 ? parts[1] : "unknown",
            "first_check": isFirstCheck
        ]
    }

    private static func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extra_large"
        case .accessoryCircular: "lock_circular"
        case .accessoryRectangular: "lock_rectangular"
        case .accessoryInline: "lock_inline"
        default: "other"
        }
    }
}
