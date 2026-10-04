import SwiftUI
import SwiftData

private enum MyWordsFilter: String, CaseIterable, Identifiable {
    case learning, know
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .learning: "Learning"
        case .know: "Know"
        }
    }
}

private enum POSFilter: String, CaseIterable, Identifiable {
    case all, noun, verb, adjective, adverb, other
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .noun: "Nouns"
        case .verb: "Verbs"
        case .adjective: "Adjectives"
        case .adverb: "Adverbs"
        case .other: "Other"
        }
    }

    static func primary(of partOfSpeech: String) -> POSFilter {
        let p = partOfSpeech.lowercased()
        if p.contains("noun") { return .noun }
        if p.contains("verb") && !p.contains("adverb") { return .verb }
        if p.contains("adjective") { return .adjective }
        if p.contains("adverb") { return .adverb }
        return .other
    }
}

struct MyWordsView: View {
    /// Incremented by `RootView` whenever the user re-taps the Vocabulary
    /// tab while already on it — used as a signal to scroll the list back
    /// to the top.
    var scrollToTopSignal: Int = 0

    @Environment(\.modelContext) private var context
    @Query(sort: \VocabularyWord.rank) private var words: [VocabularyWord]
    @Query private var progress: [LearningProgress]
    @Query(sort: \ReviewLog.reviewedAt, order: .reverse) private var reviewLogs: [ReviewLog]
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]
    @State private var isShowingProgress = false
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw = TargetLanguage.spanish.rawValue

    @State private var filter: MyWordsFilter = .learning
    @State private var posFilter: POSFilter = .all
    @State private var selectedWord: VocabularyWord?

    /// Inline "add a word" composer — revealed as a row above the list when
    /// the toolbar + is tapped. Adding words is a Pro feature, so opening the
    /// composer is gated behind the paywall.
    @State private var isComposing = false
    @State private var newWord = ""
    @State private var isLookingUp = false
    @State private var addError: String?
    @FocusState private var addFieldFocused: Bool
    @State private var entitlements = Entitlements.shared
    @State private var isShowingPaywall = false

    private let topAnchorID = "vocab-list-top"

    private var progressByID: [String: LearningProgress] {
        Dictionary(uniqueKeysWithValues: progress.map { ($0.wordID, $0) })
    }

    private var latestRatingByID: [String: ReviewRating] {
        var map: [String: ReviewRating] = [:]
        for log in reviewLogs where map[log.wordID] == nil {
            map[log.wordID] = log.rating
        }
        return map
    }

    /// Bucket a word into the Know / Learning tab — the rule lives in
    /// `VocabularyProgress` so the progress header counts exactly what the
    /// Know tab shows. Unreviewed words belong to neither tab so they don't
    /// flood "Learning" with thousands of seeded entries.
    private func bucket(
        for wordID: String,
        ratings: [String: ReviewRating],
        progressByID: [String: LearningProgress]
    ) -> MyWordsFilter? {
        if VocabularyProgress.isKnown(wordID, ratings: ratings) { return .know }
        if VocabularyProgress.isLearning(wordID, ratings: ratings, progress: progressByID[wordID]) { return .learning }
        return nil
    }

    private var currentLanguageCode: String {
        (TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish).languageCode
    }

    private var filtered: [VocabularyWord] {
        let ratings = latestRatingByID
        let progressMap = progressByID
        let language = currentLanguageCode
        return words
            .filter { word in
                // Scope to the active language so custom words from other
                // languages (which survive switches) don't leak in.
                guard word.languageCode == language else { return false }
                guard bucket(for: word.id, ratings: ratings, progressByID: progressMap) == filter else {
                    return false
                }
                return posFilter == .all || POSFilter.primary(of: word.partOfSpeech) == posFilter
            }
            .sorted { a, b in
                // Most recently rated word first — so a fresh swipe always
                // surfaces at the top of its tab. Ties (or words missing a
                // review timestamp) fall back to rank order.
                let aDate = progressMap[a.id]?.lastReviewedAt ?? .distantPast
                let bDate = progressMap[b.id]?.lastReviewedAt ?? .distantPast
                if aDate != bDate { return aDate > bDate }
                return a.rank < b.rank
            }
    }

    /// Progress header numbers, from the same data and Know rule as the list.
    private var snapshot: VocabularySnapshot {
        let ratings = latestRatingByID
        let language = currentLanguageCode
        let scoped = words.filter { $0.languageCode == language }
        let known = scoped.filter { VocabularyProgress.isKnown($0.id, ratings: ratings) }
        let knownIDs = Set(known.map(\.id))
        let ranks = StoryLexicon.cachedFrequencyRanks(for: TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish)
        let order = VocabularyProgress.learnedOrder(
            knownIDs: knownIDs,
            logs: reviewLogs.map { ($0.wordID, $0.reviewedAt, $0.rating) }
        )
        let byID = Dictionary(known.map { ($0.id, $0) }) { first, _ in first }
        return VocabularySnapshot(
            learnedCount: known.count,
            status: VocabularyProgress.milestoneStatus(learned: known.count),
            coverage: VocabularyProgress.coverage(learnedLemmas: Set(known.map(\.lemma)), ranks: ranks),
            topics: VocabularyProgress.topicFills(
                words: scoped.filter { !$0.id.hasPrefix("custom-") }.map { ($0.id, $0.deckSlugs) },
                learnedIDs: knownIDs,
                decks: decks.filter { $0.slug != DeckConstants.commonSlug }.map { ($0.slug, $0.localizedName, $0.iconSystemName) }
            ),
            learnedInOrder: order.compactMap { byID[$0] }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressHeaderCard(snapshot: snapshot) { isShowingProgress = true }
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Picker("Filter", selection: $filter) {
                ForEach(MyWordsFilter.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(POSFilter.allCases) { pos in
                            Button(pos.title) {
                                posFilter = pos
                                if pos == .all {
                                    scrollToTop(proxy: proxy)
                                }
                            }
                            .buttonStyle(.pill(selected: posFilter == pos))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                }
                .padding(.top, 24)

                List {
                    if isComposing {
                        Section {
                            addComposerRow
                        }
                    }

                    Section {
                        ForEach(filtered) { word in
                            Button {
                                selectedWord = word
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(word.lemma.capitalizedFirst)
                                        .font(.gochiHand(size: 19, relativeTo: .headline))
                                        .foregroundStyle(Color.whiteboardInk)
                                    Text(LocaleService.definition(for: word))
                                        .font(.sniglet(.subheadline))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowSeparatorTint(DS.Color.inkSeparator)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    record(rating: filter == .learning ? .good : .again, for: word)
                                } label: {
                                    switch filter {
                                    case .learning:
                                        Image(systemName: "checkmark.circle.fill")
                                            .accessibilityLabel("Know")
                                    case .know:
                                        Image(systemName: "questionmark.circle.fill")
                                            .accessibilityLabel("Learning")
                                    }
                                }
                                .tint(filter == .learning ? .green : DS.Color.ink)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(word: word)
                                } label: {
                                    Image(systemName: "trash")
                                        .accessibilityLabel("Delete")
                                }
                            }
                        }
                    } header: {
                        Text("\(filtered.count) words")
                            .sectionHeaderStyle()
                    }
                    .id(topAnchorID)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollToTopSignal) { _, _ in
                    scrollToTop(proxy: proxy)
                }
            }
        }
        .background(DS.Color.paper.ignoresSafeArea())
        .gochiHandNavigationTitle("Words")
        .deckLanguageToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if isComposing {
                        closeComposer()
                    } else if entitlements.isPro {
                        openComposer()
                    } else {
                        isShowingPaywall = true
                    }
                } label: {
                    Image(systemName: isComposing ? "xmark" : "plus")
                }
                .accessibilityLabel(isComposing ? "Cancel adding word" : "Add a word")
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(onSubscribed: openComposer, source: .myWords)
        }
        .sheet(isPresented: $isShowingProgress) {
            ProgressSheet(snapshot: snapshot)
        }
        .sheet(item: $selectedWord) { word in
            WordDetailView(
                word: word,
                knowsWord: filter == .know,
                onRate: { rating in
                    record(rating: rating, for: word)
                    selectedWord = nil
                },
                onDelete: {
                    delete(word: word)
                    selectedWord = nil
                }
            )
        }
    }

    /// Scrolls the list back to the top — anchored on the word-list section
    /// header.
    private func scrollToTop(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(topAnchorID, anchor: .top)
        }
    }

    private func openComposer() {
        withAnimation(.snappy) { isComposing = true }
    }

    private func closeComposer() {
        withAnimation(.snappy) { isComposing = false }
        newWord = ""
        addError = nil
        addFieldFocused = false
    }

    /// Inline composer row pinned to the top of the list. Type a word, submit,
    /// and it's looked up and dropped straight into the list — no sheet, no
    /// editable fields. A spinner shows during lookup; a failure shows an
    /// inline message instead of adding anything.
    private var addComposerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                TextField("Add a word you heard or saw", text: $newWord)
                    .font(.sniglet(.body))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($addFieldFocused)
                    .onSubmit { Task { await addWord() } }
                    .onChange(of: newWord) { _, _ in addError = nil }
                if isLookingUp {
                    ProgressView()
                } else {
                    Button {
                        Task { await addWord() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.sniglet(.title2))
                            .foregroundStyle(canSubmitNewWord ? DS.Color.ink : Color.secondary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmitNewWord)
                    .accessibilityLabel("Add word")
                }
            }
            if let addError {
                Text(addError)
                    .font(.sniglet(.footnote))
                    .foregroundStyle(.orange)
            }
        }
        .listRowSeparatorTint(DS.Color.inkSeparator)
        .onAppear { addFieldFocused = true }
    }

    private var canSubmitNewWord: Bool {
        !newWord.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Looks the typed word up and, on success, persists it. Clears the field
    /// and keeps focus so several words can be added in a row.
    @MainActor
    private func addWord() async {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLookingUp else { return }
        guard entitlements.isPro else {
            closeComposer()
            isShowingPaywall = true
            return
        }
        isLookingUp = true
        addError = nil

        let language = OnboardingStore.targetLanguage ?? .spanish
        let result = await WordEnrichmentService.shared.enrich(
            word: trimmed,
            targetLanguage: language,
            nativeLanguageCode: LocaleService.preferredDefinitionLocale
        )
        isLookingUp = false

        guard let result else {
            addError = String(localized: "Couldn't look that up. Check your connection and try again.")
            return
        }
        let word = persist(result, language: language)
        // Back up so the word survives an app delete/reinstall.
        Task { await CustomWordSync.pushAll(context: context) }
        newWord = ""
        // New words land in Learning; switch there so the word is visible
        // behind the detail card once it's dismissed.
        if filter != .learning { filter = .learning }
        if posFilter != .all { posFilter = .all }
        // Collapse the composer and open the new word's detail card as the
        // confirmation, rather than refocusing the field for another add.
        isComposing = false
        addFieldFocused = false
        selectedWord = word
    }

    /// Persists an enriched word and seeds it into the Learning tab — see
    /// `WordStack.persistCustomWord`, shared with the story word sheet.
    @discardableResult
    private func persist(_ enrichment: WordEnrichmentService.Enrichment, language: TargetLanguage) -> VocabularyWord {
        WordStack.persistCustomWord(enrichment, language: language, context: context)
    }

    private func delete(word: VocabularyWord) {
        let wordID = word.id
        for p in progress where p.wordID == wordID {
            context.delete(p)
        }
        for log in reviewLogs where log.wordID == wordID {
            context.delete(log)
        }
        context.delete(word)
        try? context.save()
        // Re-push the snapshot so the deletion (and any review changes) reach
        // the backup and the word doesn't reappear on reinstall.
        if wordID.hasPrefix("custom-") {
            Task { await CustomWordSync.pushAll(context: context) }
        }
    }

    private func record(rating: ReviewRating, for word: VocabularyWord) {
        let existing = progress.first { $0.wordID == word.id }
        let p = existing ?? LearningProgress(wordID: word.id)
        if existing == nil { context.insert(p) }
        let intervalBefore = p.intervalDays
        let result = SRSScheduler.next(progress: p, rating: rating)
        Analytics.capture(.cardReviewed, ["rating": "\(rating)", "source": "my_words"])
        p.state = result.state
        p.easeFactor = result.easeFactor
        p.intervalDays = result.intervalDays
        p.repetitions = result.repetitions
        p.lapses = result.lapses
        p.dueDate = result.dueDate
        p.lastReviewedAt = result.lastReviewedAt
        let log = ReviewLog(
            wordID: word.id,
            reviewedAt: result.lastReviewedAt,
            rating: rating,
            intervalBeforeDays: intervalBefore,
            intervalAfterDays: result.intervalDays
        )
        context.insert(log)
        try? context.save()
        // Rating a word here can retire it as known while today's set is still
        // frozen around it — re-publish so the widget, Live Activity and
        // reminders drop it instead of carrying it for the rest of the day.
        DailyWordService.refresh(context: context)
    }

}

private struct WordDetailView: View {
    let word: VocabularyWord
    let knowsWord: Bool
    let onRate: (ReviewRating) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.lemma.capitalizedFirst)
                            .font(.gochiHand(size: 42))
                            .foregroundStyle(Color.whiteboardInk)
                        Text(PartOfSpeechLabel.localized(word.partOfSpeech))
                            .font(.sniglet(.subheadline))
                            .foregroundStyle(.secondary)
                        Text(LocaleService.definition(for: word))
                            .font(.sniglet(.title3))
                            .padding(.top, 2)
                    }

                    InkDivider()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(word.exampleSentence)
                            .font(.sniglet(.title2))
                            .italic()
                        if let translation = LocaleService.exampleTranslation(for: word) {
                            Text(translation)
                                .font(.sniglet(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 24) {
                TintedCircleButton(
                    systemImage: "trash.fill",
                    tint: .red,
                    action: onDelete,
                    accessibilityLabel: "Delete word"
                )
                TintedCircleButton(
                    systemImage: "play.fill",
                    tint: .gray,
                    action: { SpeechService.shared.speak(word.exampleSentence) },
                    accessibilityLabel: "Play example sentence"
                )
                TintedCircleButton(
                    systemImage: knowsWord ? "questionmark" : "checkmark",
                    tint: knowsWord ? .blue : .green,
                    action: { onRate(knowsWord ? .again : .good) },
                    accessibilityLabel: rateLabel
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }

    private var rateLabel: LocalizedStringResource {
        if knowsWord { return "Move back to learning" }
        return "Mark as known"
    }
}

#Preview {
    NavigationStack { MyWordsView() }
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self], inMemory: true)
}
