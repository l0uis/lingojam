import SwiftUI
import SwiftData

struct DeckPickerSheet: View {
    let decks: [Deck]
    @Binding var selectedSlug: String
    @Binding var selectedLevel: String
    @Binding var selectedLanguageRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var pendingLanguage: TargetLanguage?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                        spacing: 12
                    ) {
                        ForEach(TargetLanguage.allCases) { language in
                            languageTile(language: language)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("Language")
                }

                Section {
                    ForEach(DeckConstants.cefrLevels, id: \.self) { level in
                        levelChip(level: level, title: level)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader("Level")
                }

                Section {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                        spacing: 16
                    ) {
                        deckTile(slug: DeckConstants.allSlug, title: "All Words")
                        ForEach(decks, id: \.slug) { deck in
                            deckTile(slug: deck.slug, title: deck.displayName)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("Deck")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Switch to \(pendingLanguage?.title ?? "")?",
                isPresented: Binding(
                    get: { pendingLanguage != nil },
                    set: { if !$0 { pendingLanguage = nil } }
                ),
                presenting: pendingLanguage
            ) { language in
                Button("Switch", role: .destructive) {
                    SeedDataLoader.switchLanguage(to: language, context: context)
                    pendingLanguage = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { pendingLanguage = nil }
            } message: { _ in
                Text("This replaces your current vocabulary and resets your learning progress.")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).sectionHeaderStyle()
    }

    @ViewBuilder
    private func languageTile(language: TargetLanguage) -> some View {
        let isSelected = selectedLanguageRaw == language.rawValue
        Button {
            guard !isSelected else { return }
            pendingLanguage = language
        } label: {
            VStack(spacing: 6) {
                Image(language.flagAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    )
                Text(language.title)
                    .font(.sniglet(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func levelChip(level: String, title: String) -> some View {
        Button {
            selectedLevel = level
        } label: {
            HStack {
                Text(title)
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if selectedLevel == level {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.subheadline, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deckTile(slug: String, title: String) -> some View {
        let isSelected = selectedSlug == slug
        Button {
            selectedSlug = slug
            dismiss()
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tileColor(for: slug))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    )
                Text(title)
                    .font(.sniglet(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .buttonStyle(.plain)
    }

    private func tileColor(for slug: String) -> Color {
        if slug == DeckConstants.allSlug {
            return Color.secondary.opacity(0.35)
        }
        var hasher = Hasher()
        hasher.combine(slug)
        let hue = Double(UInt32(truncatingIfNeeded: hasher.finalize()) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

// MARK: - Toolbar modifier

private struct DeckLanguageToolbarModifier: ViewModifier {
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]
    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage(DeckConstants.selectedCEFRLevelDefaultsKey) private var selectedCEFRLevel: String = DeckConstants.defaultCEFRLevel
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @State private var isShowingDeckPicker: Bool = false

    private var currentLanguage: TargetLanguage {
        TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingDeckPicker = true
                    } label: {
                        Image(currentLanguage.flagAssetName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .accessibilityLabel("Choose deck and language")
                }
            }
            .sheet(isPresented: $isShowingDeckPicker) {
                DeckPickerSheet(
                    decks: decks,
                    selectedSlug: $selectedDeckSlug,
                    selectedLevel: $selectedCEFRLevel,
                    selectedLanguageRaw: $targetLanguageRaw
                )
            }
    }
}

extension View {
    /// Adds the language flag button to the navigation bar's top-left; tapping
    /// it presents the shared deck/level/language picker sheet. Apply once
    /// per top-level tab view.
    func deckLanguageToolbar() -> some View {
        modifier(DeckLanguageToolbarModifier())
    }
}
