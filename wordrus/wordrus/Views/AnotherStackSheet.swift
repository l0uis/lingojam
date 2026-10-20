import SwiftUI

/// "Start another stack", offered on the end-of-day card once the daily set is
/// done: Pro picks any theme and swipes on. Free users hit the paywall before
/// this opens (see `JamView`); the locks here are a fallback for Pro lapsing
/// while the sheet is up — tapping one opens the paywall and the stack starts
/// the moment they subscribe.
struct AnotherStackSheet: View {
    let themes: [Deck]
    /// Slug of the theme the user just finished today, marked as done.
    let finishedSlug: String?
    let onPick: (Deck) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = Entitlements.shared
    @State private var isShowingPaywall = false
    /// The deck a free user tapped; started once the paywall closes with Pro.
    @State private var pendingDeck: Deck?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(themes, id: \.slug) { deck in
                        row(deck)
                    }
                } header: {
                    Text(entitlements.isPro ? "Pick a theme" : "Unlimited stacks with Pro")
                        .sectionHeaderStyle()
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Another stack")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingPaywall, onDismiss: startPendingIfSubscribed) {
                PaywallView(source: .anotherStack)
            }
        }
    }

    /// Runs after the paywall has fully closed, so starting the stack and
    /// dismissing this sheet don't race the paywall's own dismissal.
    private func startPendingIfSubscribed() {
        defer { pendingDeck = nil }
        guard entitlements.isPro, let deck = pendingDeck else { return }
        onPick(deck)
        dismiss()
    }

    private func row(_ deck: Deck) -> some View {
        Button {
            guard entitlements.isPro else {
                pendingDeck = deck
                isShowingPaywall = true
                return
            }
            onPick(deck)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: deck.iconSystemName)
                    .font(.sniglet(.title3))
                    .foregroundStyle(DS.Color.ink)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.localizedName)
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(Color.whiteboardInk)
                    if deck.slug == finishedSlug {
                        Text("Done today")
                            .font(.sniglet(.caption))
                            .foregroundStyle(.secondary)
                    } else if !deck.localizedDescription.isEmpty {
                        Text(deck.localizedDescription)
                            .font(.sniglet(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: entitlements.isPro ? "chevron.right" : "lock.fill")
                    .font(.sniglet(.caption, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
