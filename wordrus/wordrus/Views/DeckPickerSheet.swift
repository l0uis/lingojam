import SwiftUI
import SwiftData

struct DeckPickerSheet: View {
    let decks: [Deck]
    @Binding var selectedSlug: String
    @Binding var selectedLevel: String
    @Binding var selectedLanguageRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allWords: [VocabularyWord]
    @State private var pendingLanguage: TargetLanguage?

    /// CEFR levels that actually have words in the currently-loaded language,
    /// in canonical order. Only Spanish is leveled past A2; FR/DE/IT have just
    /// A1/A2, so offering C1 etc. would let the user filter to an empty pool.
    private var availableLevels: [String] {
        let present = Set(allWords.compactMap(\.cefrLevel))
        return DeckConstants.cefrLevels.filter { present.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                        spacing: 20
                    ) {
                        ForEach(TargetLanguage.allCases) { language in
                            languageTile(language: language)
                        }
                    }
                    .padding(.vertical, 20)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                } header: {
                    sectionHeader("Language")
                }

                if availableLevels.count > 1 {
                    Section {
                        ForEach(availableLevels, id: \.self) { level in
                            levelChip(level: level, title: level)
                        }
                    } header: {
                        sectionHeader("Level")
                    }
                }

                Section {
                    deckRow(slug: DeckConstants.allSlug, title: "All Words")
                    ForEach(decks, id: \.slug) { deck in
                        deckRow(slug: deck.slug, title: deck.displayName)
                    }
                } header: {
                    sectionHeader("Deck")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Filter")
            .onAppear(perform: clampLevelToAvailable)
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

    /// Snap a stale selection (e.g. C1 carried over from Spanish) back to a
    /// level the current language actually has, so the filter never points at
    /// an empty pool.
    private func clampLevelToAvailable() {
        guard !availableLevels.isEmpty, !availableLevels.contains(selectedLevel) else { return }
        selectedLevel = availableLevels.first ?? DeckConstants.defaultCEFRLevel
    }

    @ViewBuilder
    private func languageTile(language: TargetLanguage) -> some View {
        let isSelected = selectedLanguageRaw == language.rawValue
        Button {
            guard !isSelected else { return }
            pendingLanguage = language
        } label: {
            VStack(spacing: 8) {
                Image(language.flagAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .padding(5)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    )
                Text(language.title)
                    .font(.sniglet(.caption, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
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
                    .font(.sniglet(.body))
                    .foregroundStyle(Color.whiteboardInk)
                Spacer()
                if selectedLevel == level {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(DS.Color.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deckRow(slug: String, title: String) -> some View {
        Button {
            selectedSlug = slug
        } label: {
            HStack {
                Text(title)
                    .font(.sniglet(.body))
                    .foregroundStyle(Color.whiteboardInk)
                Spacer()
                if selectedSlug == slug {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(DS.Color.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar modifier

private struct DeckLanguageToolbarModifier: ViewModifier {
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]
    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage(DeckConstants.selectedCEFRLevelDefaultsKey) private var selectedCEFRLevel: String = DeckConstants.defaultCEFRLevel
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @State private var localIsShowingDeckPicker: Bool = false

    var externalIsPresented: Binding<Bool>?

    private var isShowingDeckPicker: Binding<Bool> {
        externalIsPresented ?? $localIsShowingDeckPicker
    }

    private var currentLanguage: TargetLanguage {
        TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingDeckPicker.wrappedValue = true
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
            .sheet(isPresented: isShowingDeckPicker) {
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
    /// per top-level tab view. Pass `isPresented` to observe sheet state
    /// (e.g. to pause audio playback that would otherwise fire under the sheet).
    func deckLanguageToolbar(isPresented: Binding<Bool>? = nil) -> some View {
        modifier(DeckLanguageToolbarModifier(externalIsPresented: isPresented))
    }
}
