import SwiftUI
import SwiftData

/// Confirms a move to another target language. Switching is a big step —
/// the deck, Dr Tusk's calls and the stories all change language — so it
/// gets a full sheet rather than an alert: what's being kept from the
/// language you're leaving, where you stand with the one you're moving to,
/// and, the first time, your level in it.
struct LanguageSwitchSheet: View {
    let language: TargetLanguage
    let onSwitch: (_ firstTimeLevel: CEFRLevel?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var entitlements = Entitlements.shared
    @State private var leaving: (language: TargetLanguage, summary: LanguageSwitcher.Summary?)?
    @State private var returning: LanguageSwitcher.Summary?
    @State private var level: CEFRLevel?
    @State private var didLoad = false

    private var isFirstTime: Bool { didLoad && returning == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if let leaving {
                        leavingCard(leaving.language, summary: leaving.summary)
                    }

                    if let returning {
                        returningCard(returning)
                    } else if isFirstTime {
                        levelPicker
                    }

                    changes
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Switch to \(language.title)") {
                    onSwitch(isFirstTime ? level : nil)
                    dismiss()
                }
                .buttonStyle(.primary)
                .disabled(isFirstTime && level == nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(DS.Color.paper)
            }
            .background(DS.Color.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        // Same fallback as the rest of the app when no language is stored.
        let current = OnboardingStore.targetLanguage ?? .spanish
        leaving = (current, LanguageSwitcher.summary(for: current, context: context))
        returning = LanguageSwitcher.summary(for: language, context: context)
        didLoad = true
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(language.flagAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(Circle())
            Text("Switch to \(language.title)?")
                .font(.sniglet(.title, weight: .bold))
                .foregroundStyle(DS.Color.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func leavingCard(_ previous: TargetLanguage, summary: LanguageSwitcher.Summary?) -> some View {
        card(flag: previous.flagAssetName) {
            Text("Your \(previous.title) is saved")
                .font(.sniglet(.headline, weight: .bold))
                .foregroundStyle(DS.Color.ink)
            if let summary {
                Text(statsLine(summary))
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Text("Everything's kept — switch back any time and carry on where you left off.")
                .font(.sniglet(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func returningCard(_ summary: LanguageSwitcher.Summary) -> some View {
        card(flag: language.flagAssetName) {
            Text("Welcome back to \(language.title)")
                .font(.sniglet(.headline, weight: .bold))
                .foregroundStyle(DS.Color.ink)
            Text(statsLine(summary))
                .font(.sniglet(.subheadline))
                .foregroundStyle(.secondary)
            Text("You'll pick up right where you left off.")
                .font(.sniglet(.subheadline))
                .foregroundStyle(.secondary)
        }
    }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where are you with \(language.titleInSentence)?")
                .font(.sniglet(.headline, weight: .bold))
                .foregroundStyle(DS.Color.ink)
            Text("A1 is brand new, C2 is near-native. You can change it later.")
                .font(.sniglet(.subheadline))
                .foregroundStyle(.secondary)
            ForEach(CEFRLevel.allCases) { option in
                SelectableRow(
                    title: option.title,
                    subtitle: option.subtitle,
                    inlineSubtitle: true,
                    prominentTitle: true,
                    isSelected: level == option
                ) {
                    level = option
                }
            }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What changes")
                .font(.sniglet(.headline, weight: .bold))
                .foregroundStyle(DS.Color.ink)
            changeRow("rectangle.stack.fill", "Your daily cards are in \(language.titleInSentence)")
            changeRow("phone.fill", "Dr Tusk calls you in \(language.titleInSentence)")
            if entitlements.isPro {
                changeRow("book.fill", "Today's story is written in \(language.titleInSentence)")
            }
        }
    }

    // MARK: - Pieces

    private func statsLine(_ summary: LanguageSwitcher.Summary) -> String {
        var parts = [summary.level.title, String(localized: "\(summary.knownWords) words known")]
        if summary.stories > 0 {
            parts.append(String(localized: "\(summary.stories) stories"))
        }
        return parts.joined(separator: " · ")
    }

    private func changeRow(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.ink)
                .frame(width: 28)
            Text(text)
                .font(.sniglet(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(flag: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(flag)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        )
    }
}
