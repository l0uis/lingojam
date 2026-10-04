import SwiftUI

/// Everything the progress header and sheet show, computed once per render
/// by `MyWordsView` from the same data as its Know tab.
struct VocabularySnapshot {
    let learnedCount: Int
    let status: MilestoneStatus
    /// 0…1, frequency-weighted (see `VocabularyProgress.coverage`).
    let coverage: Double
    let topics: [VocabularyProgress.TopicFill]
    /// Known words in the order they were learned.
    let learnedInOrder: [VocabularyWord]

    /// "~34%", or "<1%" for a first handful of words (never a discouraging
    /// "0%" once anything is learned). Rounded down so it never overstates.
    var coverageText: String {
        let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(0))) }
        if coverage <= 0 { return percent(0) }
        if coverage < 0.01 { return "<" + percent(0.01) }
        return "~" + percent(floor(coverage * 100) / 100)
    }
}

/// The card at the top of the Words tab: how many words, the next milestone,
/// and how much everyday language that covers. Tapping opens the full view.
struct ProgressHeaderCard: View {
    let snapshot: VocabularySnapshot
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.learnedCount, format: .number)
                        .font(.gochiHand(size: 34, relativeTo: .largeTitle))
                        .foregroundStyle(DS.Color.ink)
                    Text(snapshot.learnedCount == 1 ? "word learned" : "words learned")
                        .font(.sniglet(.headline))
                        .foregroundStyle(DS.Color.charcoal)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.sniglet(.subheadline, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                if let next = snapshot.status.next {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: next.systemImage)
                                .accessibilityHidden(true)
                            Text("Next: \(String(localized: next.title))")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(snapshot.status.remaining) to go")
                                .foregroundStyle(.secondary)
                        }
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(DS.Color.charcoal)
                        ProgressView(value: snapshot.status.fraction)
                            .tint(DS.Color.ink)
                            .accessibilityHidden(true)
                    }
                } else {
                    Label("Every milestone reached!", systemImage: "sparkles")
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(DS.Color.charcoal)
                }

                Text("You know \(snapshot.coverageText) of everyday words")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            .tintedSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Text("Shows your milestones and topics."))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: Text {
        if let next = snapshot.status.next {
            return Text("\(snapshot.learnedCount) words learned. Next milestone: \(String(localized: next.title)), \(snapshot.status.remaining) to go. You know about \(snapshot.coverageText) of everyday words.")
        }
        return Text("\(snapshot.learnedCount) words learned. Every milestone reached. You know about \(snapshot.coverageText) of everyday words.")
    }
}

/// Milestones, everyday-word coverage and the topic map.
struct ProgressSheet: View {
    let snapshot: VocabularySnapshot

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Milestones.all) { milestone in
                        if milestone.count <= snapshot.learnedCount {
                            NavigationLink {
                                MilestoneWordsView(
                                    milestone: milestone,
                                    words: Array(snapshot.learnedInOrder.prefix(milestone.count))
                                )
                            } label: {
                                MilestoneRow(milestone: milestone, state: .reached)
                            }
                        } else {
                            MilestoneRow(
                                milestone: milestone,
                                state: milestone == snapshot.status.next ? .next(remaining: snapshot.status.remaining) : .upcoming
                            )
                        }
                    }
                } header: {
                    Text("Milestones").sectionHeaderStyle()
                } footer: {
                    Text("Tap a milestone you've reached to see the words that got you there.")
                        .font(.sniglet(.caption))
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.coverageText)
                            .font(.gochiHand(size: 36, relativeTo: .largeTitle))
                            .foregroundStyle(DS.Color.ink)
                        Text("of everyday words — common words count for more, so the first few hundred go a long way.")
                            .font(.sniglet(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Everyday words").sectionHeaderStyle()
                }

                if !snapshot.topics.isEmpty {
                    Section {
                        ForEach(snapshot.topics) { topic in
                            TopicRow(topic: topic)
                        }
                    } header: {
                        Text("Topic map").sectionHeaderStyle()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .navigationTitle("Your progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MilestoneRow: View {
    enum State: Equatable {
        case reached
        case next(remaining: Int)
        case upcoming
    }

    let milestone: Milestone
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: milestone.systemImage)
                .font(.sniglet(.subheadline, weight: .bold))
                .foregroundStyle(state == .reached ? .white : DS.Color.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(state == .reached ? DS.Color.ink : DS.Color.inkTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(state == .upcoming ? Color.secondary : DS.Color.charcoal)
                Text(milestone.detail)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.sniglet(.caption, weight: .bold))
                    .foregroundStyle(state == .reached ? DS.Color.ink : Color.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch state {
        case .reached: String(localized: "\(milestone.count) words · reached")
        case .next(let remaining): String(localized: "\(milestone.count) words · \(remaining) to go")
        case .upcoming: String(localized: "\(milestone.count) words")
        }
    }
}

private struct TopicRow: View {
    let topic: VocabularyProgress.TopicFill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: topic.systemImage)
                    .foregroundStyle(DS.Color.ink)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(topic.name)
                    .font(.sniglet(.body))
                    .foregroundStyle(DS.Color.charcoal)
                Spacer(minLength: 8)
                Text("\(topic.learned) / \(topic.total)")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: topic.fraction)
                .tint(DS.Color.ink)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(topic.name): \(topic.learned) of \(topic.total) words learned"))
    }
}

/// The words that got the learner to a milestone, in the order they learned them.
private struct MilestoneWordsView: View {
    let milestone: Milestone
    let words: [VocabularyWord]

    var body: some View {
        List {
            Section {
                ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.sniglet(.caption))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.lemma.capitalizedFirst)
                                .font(.gochiHand(size: 19, relativeTo: .headline))
                                .foregroundStyle(Color.whiteboardInk)
                            Text(LocaleService.definition(for: word))
                                .font(.sniglet(.subheadline))
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(milestone.detail)
                    .font(.sniglet(.subheadline))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.Color.paper.ignoresSafeArea())
        .navigationTitle(Text(milestone.title))
        .navigationBarTitleDisplayMode(.inline)
    }
}
