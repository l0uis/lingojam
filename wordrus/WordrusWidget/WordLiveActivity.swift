import ActivityKit
import WidgetKit
import SwiftUI

/// The rotating-word Live Activity. Content advances through the day (driven by
/// `LiveActivityService` in the app); this file only renders whatever word the
/// current `ContentState` carries.
///
/// Two surfaces with *opposite* backgrounds need opposite text colours:
///   • Lock Screen banner → paper (cream) background, so dark ink text.
///   • Dynamic Island      → system black pill, so light (paper) text.
/// Live Activities also apply a vibrancy pass that (a) turns `.primary`/
/// `.secondary` near-white and (b) force-templates bitmap images into a flat
/// filled shape — which is why we use SF Symbols (designed to tint) rather than
/// the walrus artwork here, and set an explicit colour on every label.
struct WordLiveActivity: Widget {
    /// SF Symbol used as the wordmark across every surface — tints crisply
    /// where the bitmap mascot would render as a flat blob.
    private static let glyph = "text.book.closed.fill"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WordActivityAttributes.self) { context in
            LiveActivityLockScreenView(state: context.state)
                .activityBackgroundTint(DS.Color.paper)
                .activitySystemActionForegroundColor(DS.Color.ink)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: Self.glyph)
                        .font(.title3)
                        .foregroundStyle(DS.Color.inkHighlight)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.index + 1)/\(context.state.total)")
                        .font(.sniglet(.caption))
                        .foregroundStyle(DS.Color.paper.opacity(0.6))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.lemma.capitalizedFirst)
                            .font(.gochiHand(size: 24, relativeTo: .title3))
                            .foregroundStyle(DS.Color.paper)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(snapshot.definition)
                            .font(.sniglet(.subheadline))
                            .foregroundStyle(DS.Color.paper.opacity(0.85))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: Self.glyph)
                    .foregroundStyle(DS.Color.paper)
            } compactTrailing: {
                Text(snapshot.lemma.capitalizedFirst)
                    .font(.sniglet(.caption, weight: .semibold))
                    .foregroundStyle(DS.Color.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 68)
            } minimal: {
                Image(systemName: Self.glyph)
                    .foregroundStyle(DS.Color.paper)
            }
            .widgetURL(Self.deepLink(for: snapshot))
            .keylineTint(DS.Color.inkHighlight)
        }
    }

    static func deepLink(for snapshot: DailyWordSnapshot) -> URL? {
        guard !snapshot.wordID.isEmpty else { return nil }
        return URL(string: "wordrus://word/\(snapshot.wordID)")
    }
}

/// Lock Screen / banner presentation — dark ink text on the paper background,
/// with a subtle wordmark + "n of total" progress marker on the trailing edge.
struct LiveActivityLockScreenView: View {
    let state: WordActivityAttributes.ContentState

    private var snapshot: DailyWordSnapshot { state.snapshot }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.lemma.capitalizedFirst)
                    .font(.gochiHand(size: 30, relativeTo: .title2))
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(snapshot.definition)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(DS.Color.charcoal)
                    .lineLimit(1)
                if !snapshot.exampleSentence.isEmpty {
                    Text(snapshot.exampleSentence)
                        .font(.sniglet(.caption).italic())
                        .foregroundStyle(DS.Color.charcoal.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(DS.Color.ink.opacity(0.75))
                Text("\(state.index + 1)/\(state.total)")
                    .font(.sniglet(.caption2))
                    .foregroundStyle(DS.Color.charcoal.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .widgetURL(WordLiveActivity.deepLink(for: snapshot))
    }
}
