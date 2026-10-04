import WidgetKit
import SwiftUI

struct DailyWordEntry: TimelineEntry {
    let date: Date
    let snapshot: DailyWordSnapshot?

    static let placeholder = DailyWordEntry(
        date: .now,
        snapshot: DailyWordSnapshot(
            wordID: "placeholder",
            lemma: "hola",
            partOfSpeech: "interjection",
            definition: "hello",
            exampleSentence: "Hola, ¿cómo estás?",
            exampleTranslation: "Hello, how are you?",
            isDueNow: true,
            dueDate: .now,
            computedAt: .now
        )
    )
}

struct DailyWordProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyWordEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyWordEntry) -> Void) {
        let snapshot = DailyWordSnapshot.load()
        completion(DailyWordEntry(date: .now, snapshot: snapshot ?? DailyWordEntry.placeholder.snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyWordEntry>) -> Void) {
        let now = Date()

        // Preferred path: rotate through today's whole stack so the widget
        // changes throughout the day on its own, even while the app is closed.
        if let set = DailyWordSet.load(), !set.words.isEmpty {
            let words = set.words
            // Spread the set across the waking day, clamped so a tiny set still
            // changes a few times and a large one doesn't flip too fast. Shared
            // with the Live Activity so both agree on the rotation cadence.
            let interval = DailyWordRotation.interval(count: words.count)
            // Cover a full 24h of entries, cycling the list, then ask again.
            let entryCount = min(64, Int((24 * 3600) / interval) + 1)
            let entries = (0..<entryCount).map { i -> DailyWordEntry in
                let date = now.addingTimeInterval(Double(i) * interval)
                return DailyWordEntry(date: date, snapshot: words[i % words.count])
            }
            completion(Timeline(entries: entries, policy: .atEnd))
            return
        }

        // Fallback: single stored snapshot (e.g. before the first set is built).
        let entry = DailyWordEntry(date: now, snapshot: DailyWordSnapshot.load())
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 6, to: now) ?? now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct DailyWordWidget: Widget {
    let kind: String = "DailyWordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyWordProvider()) { entry in
            DailyWordWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Daily Word")
        .description("Your next word to review.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DailyWordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: DailyWordEntry

    /// The widget sits on the system's tertiary fill, which goes dark in dark
    /// mode — the ink navy is unreadable against it. `DS.Color.ink` stays
    /// right in the app itself, which always renders on cream paper, so this
    /// override belongs here rather than in the shared token.
    private var titleColor: Color {
        colorScheme == .dark ? .white : DS.Color.ink
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: walrusWidth)
                .offset(x: walrusOffset.x, y: walrusOffset.y)
                .allowsHitTesting(false)
        }
        .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        guard let id = entry.snapshot?.wordID, !id.isEmpty else { return nil }
        return URL(string: "wordrus://word/\(id)")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                mediumView(snapshot)
            default:
                smallView(snapshot)
            }
        } else {
            emptyView
        }
    }

    private var walrusWidth: CGFloat {
        family == .systemMedium ? 90 : 70
    }

    private var walrusOffset: (x: CGFloat, y: CGFloat) {
        family == .systemMedium ? (28, 56) : (24, 48)
    }

    private func smallView(_ snapshot: DailyWordSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.lemma.capitalizedFirst)
                .font(.gochiHand(size: 28, relativeTo: .title2))
                .foregroundStyle(titleColor)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            Text(snapshot.definition)
                .font(.sniglet(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediumView(_ snapshot: DailyWordSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.lemma.capitalizedFirst)
                    .font(.gochiHand(size: 34, relativeTo: .title))
                    .foregroundStyle(titleColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(snapshot.definition)
                    .font(.sniglet(.callout))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            if !snapshot.exampleSentence.isEmpty {
                InkDivider()
                    .padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.exampleSentence)
                        .font(.sniglet(.subheadline).italic())
                        .lineLimit(2)
                    if let translation = snapshot.exampleTranslation, !translation.isEmpty {
                        Text(translation)
                            .font(.sniglet(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("wordrus")
                .font(.sniglet(.headline))
            Text("Open the app to load your first word.")
                .font(.sniglet(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemSmall) {
    DailyWordWidget()
} timeline: {
    DailyWordEntry.placeholder
}

#Preview(as: .systemMedium) {
    DailyWordWidget()
} timeline: {
    DailyWordEntry.placeholder
}
