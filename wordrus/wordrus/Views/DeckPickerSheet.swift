import SwiftUI
import SwiftData

struct DeckPickerSheet: View {
    let decks: [Deck]
    @Binding var selectedSlug: String
    @Binding var selectedLanguageRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var pendingLanguage: TargetLanguage?
    @State private var entitlements = Entitlements.shared
    /// Surfaced when a free user tries to change deck or language — choosing
    /// your own content is a Pro perk (content-breadth gate). The pending
    /// change is replayed once they subscribe.
    @State private var isShowingPaywall: Bool = false
    @State private var pendingChange: PendingChange?
    @AppStorage(OnboardingDefaultsKey.cefrLevel) private var cefrLevelRaw: String = CEFRLevel.a1.rawValue
    @State private var levelStatus: LevelProgression.Status?

    private var offeredLanguages: [TargetLanguage] {
        TargetLanguage.offered(to: NativeLanguage.current)
    }

    /// A filter change a free user attempted; applied after they go Pro.
    private enum PendingChange {
        case deck(String)
        case language(TargetLanguage)
    }

    var body: some View {
        NavigationStack {
            List {
                // Non-English speakers have exactly one target (English), so
                // there's nothing to switch between.
                if offeredLanguages.count > 1 {
                    Section {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                            spacing: 20
                        ) {
                            ForEach(offeredLanguages) { language in
                                languageTile(language: language)
                            }
                        }
                        .padding(.vertical, 20)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    } header: {
                        sectionHeader("Language")
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        ForEach(CEFRLevel.allCases) { level in
                            levelChip(level)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))

                    if let status = levelStatus, !status.isMaxLevel, status.eligible {
                        progressRow(status)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
                    }
                } header: {
                    sectionHeader("Level")
                }

                Section {
                    deckRow(slug: DeckConstants.allSlug, title: String(localized: "All Words"))
                    ForEach(decks, id: \.slug) { deck in
                        deckRow(slug: deck.slug, title: deck.localizedName)
                    }
                } header: {
                    sectionHeader("Deck")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Filter")
            .onAppear { levelStatus = LevelProgression.status(context: context) }
            .onChange(of: cefrLevelRaw) { levelStatus = LevelProgression.status(context: context) }
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
                Button("Switch") {
                    SeedDataLoader.switchLanguage(to: language, context: context)
                    pendingLanguage = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { pendingLanguage = nil }
            } message: { language in
                Text("Your current words and progress are kept — they come back if you switch back to them. You'll now see \(language.title).")
            }
            .sheet(isPresented: $isShowingPaywall, onDismiss: { pendingChange = nil }) {
                // Once subscribed, replay the change the user attempted.
                PaywallView(onSubscribed: applyPendingChange, source: .deckPicker)
            }
        }
    }

    /// Apply the deck/level/language change a free user tapped before the
    /// paywall intervened. Language routes through `pendingLanguage` so the
    /// destructive "resets your progress" confirmation still shows.
    private func applyPendingChange() {
        switch pendingChange {
        case .deck(let slug): selectedSlug = slug
        case .language(let language): pendingLanguage = language
        case nil: break
        }
        pendingChange = nil
    }

    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title).sectionHeaderStyle()
    }

    @ViewBuilder
    private func languageTile(language: TargetLanguage) -> some View {
        let isSelected = selectedLanguageRaw == language.rawValue
        Button {
            guard !isSelected else { return }
            guard entitlements.isPro else {
                pendingChange = .language(language)
                isShowingPaywall = true
                return
            }
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
    private func progressRow(_ status: LevelProgression.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.eligible, let next = status.next {
                Button {
                    LevelProgression.promote()
                    cefrLevelRaw = next.rawValue   // drives the chips + LevelAnchor refresh
                    levelStatus = LevelProgression.status(context: context)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Move up to \(next.title)")
                            .font(.sniglet(.body, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .foregroundStyle(DS.Color.paper)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Color.ink)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func levelChip(_ level: CEFRLevel) -> some View {
        let isSelected = cefrLevelRaw == level.rawValue
        Button {
            guard !isSelected else { return }
            cefrLevelRaw = level.rawValue
            // A manual level change restarts progress toward the next
            // chat-based promotion at the new level.
            UserDefaults.standard.set(0, forKey: OnboardingDefaultsKey.cefrPassesAtCurrentLevel)
        } label: {
            Text(level.title)
                .font(.sniglet(.body, weight: .semibold))
                .foregroundStyle(isSelected ? DS.Color.paper : Color.whiteboardInk)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(isSelected ? DS.Color.ink : DS.Color.paper)
                )
                .overlay(
                    Circle().strokeBorder(DS.Color.ink.opacity(isSelected ? 0 : 0.35), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level.title): \(level.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func deckRow(slug: String, title: String) -> some View {
        Button {
            guard selectedSlug != slug else { return }
            guard entitlements.isPro else {
                pendingChange = .deck(slug)
                isShowingPaywall = true
                return
            }
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
