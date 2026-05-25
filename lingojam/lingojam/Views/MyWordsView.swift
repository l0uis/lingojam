import SwiftUI
import SwiftData

private enum MyWordsFilter: String, CaseIterable, Identifiable {
    case learning, know
    var id: String { rawValue }
    var title: String {
        switch self {
        case .learning: "Learning"
        case .know: "Know"
        }
    }
}

private enum POSFilter: String, CaseIterable, Identifiable {
    case all, noun, verb, adjective, adverb, other
    var id: String { rawValue }
    var title: String {
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

    @State private var filter: MyWordsFilter = .learning
    @State private var posFilter: POSFilter = .all
    @State private var selectedWord: VocabularyWord?

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

    /// Bucket a word into the Know / Learning tab based on the user's most
    /// recent rating for it. Unreviewed words belong to neither tab so they
    /// don't flood "Learning" with thousands of seeded entries.
    ///
    /// We consult the latest `ReviewLog` first (most precise — reflects the
    /// user's most recent swipe), then fall back to `LearningProgress` so
    /// words the user has swiped don't-know still surface in Learning even
    /// if the log query is briefly stale or older data is missing logs.
    private func bucket(
        for wordID: String,
        ratings: [String: ReviewRating],
        progressByID: [String: LearningProgress]
    ) -> MyWordsFilter? {
        if let rating = ratings[wordID] {
            switch rating {
            case .good, .easy: return .know
            case .again, .hard: return .learning
            }
        }
        // Fallback signal: any word that's been actively swiped will have
        // lapses > 0 (a don't-know was recorded at some point) or a non-new
        // SRS state. Without a ReviewLog we can't tell if the *latest* swipe
        // was know/don't-know, so we conservatively put it in Learning —
        // anything the user has explicitly marked Known will have a log.
        if let p = progressByID[wordID], p.lapses > 0 || p.state == .learning || p.state == .review {
            return .learning
        }
        return nil
    }

    private var filtered: [VocabularyWord] {
        let ratings = latestRatingByID
        let progressMap = progressByID
        return words
            .filter { word in
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

    private var knownCountForPOS: Int {
        let ratings = latestRatingByID
        let progressMap = progressByID
        return words.reduce(0) { acc, word in
            let matchesPOS = posFilter == .all || POSFilter.primary(of: word.partOfSpeech) == posFilter
            return acc + (matchesPOS && bucket(for: word.id, ratings: ratings, progressByID: progressMap) == .know ? 1 : 0)
        }
    }

    private var knownCountLabel: String {
        switch posFilter {
        case .all: knownCountForPOS == 1 ? "word" : "words"
        case .noun: knownCountForPOS == 1 ? "noun" : "nouns"
        case .verb: knownCountForPOS == 1 ? "verb" : "verbs"
        case .adjective: knownCountForPOS == 1 ? "adjective" : "adjectives"
        case .adverb: knownCountForPOS == 1 ? "adverb" : "adverbs"
        case .other: knownCountForPOS == 1 ? "word" : "words"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    if filter == .know {
                        Section {
                            knownCountBanner
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .id(topAnchorID)
                        }
                    }

                    Section {
                        ForEach(filtered) { word in
                            Button {
                                selectedWord = word
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(word.lemma.capitalizedFirst)
                                        .font(.gochiHand(size: 30, relativeTo: .headline))
                                        .foregroundStyle(Color.whiteboardInk)
                                    Text(LocaleService.definition(for: word))
                                        .font(.sniglet(.subheadline))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparatorTint(DS.Color.inkSeparator)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    record(rating: filter == .learning ? .good : .again, for: word)
                                } label: {
                                    switch filter {
                                    case .learning: Label("Know", systemImage: "checkmark")
                                    case .know: Label("Learning", systemImage: "arrow.uturn.backward")
                                    }
                                }
                                .tint(filter == .learning ? .green : .blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(word: word)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("\(filtered.count) \(filtered.count == 1 ? "word" : "words")")
                            .sectionHeaderStyle()
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollToTopSignal) { _, _ in
                    scrollToTop(proxy: proxy)
                }
            }
        }
        .background(DS.Color.paper.ignoresSafeArea())
        .gochiHandNavigationTitle("Vocabulary")
        .deckLanguageToolbar()
        .sheet(item: $selectedWord) { word in
            WordDetailView(
                word: word,
                progress: progressByID[word.id],
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

    private var knownCountBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(knownCountForPOS)")
                .font(.gochiHand(size: 56))
                .foregroundStyle(DS.Color.ink)
            Text("\(knownCountLabel) you know")
                .font(.sniglet(.title3, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .tintedSurface()
    }

    /// Scrolls the list back to the top. When the Know banner is showing,
    /// the banner row holds the top anchor; otherwise we target the first
    /// word row by its id.
    private func scrollToTop(proxy: ScrollViewProxy) {
        withAnimation {
            if filter == .know {
                proxy.scrollTo(topAnchorID, anchor: .top)
            } else if let firstID = filtered.first?.id {
                proxy.scrollTo(firstID, anchor: .top)
            }
        }
    }

    private func delete(word: VocabularyWord) {
        for p in progress where p.wordID == word.id {
            context.delete(p)
        }
        for log in reviewLogs where log.wordID == word.id {
            context.delete(log)
        }
        context.delete(word)
        try? context.save()
    }

    private func record(rating: ReviewRating, for word: VocabularyWord) {
        let existing = progress.first { $0.wordID == word.id }
        let p = existing ?? LearningProgress(wordID: word.id)
        if existing == nil { context.insert(p) }
        let intervalBefore = p.intervalDays
        let result = SRSScheduler.next(progress: p, rating: rating)
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
    }

}

private struct WordDetailView: View {
    let word: VocabularyWord
    let progress: LearningProgress?
    let knowsWord: Bool
    let onRate: (ReviewRating) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.lemma.capitalizedFirst)
                            .font(.gochiHand(size: 52))
                            .foregroundStyle(Color.whiteboardInk)
                        Text(word.partOfSpeech)
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

                    if let progress {
                        InkDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Progress")
                                .font(.sniglet(.headline))
                            Text("Interval: \(progress.intervalDays) day(s)")
                            Text("Repetitions: \(progress.repetitions)")
                            Text("Due: \(progress.dueDate.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                TintedCircleButton(
                    systemImage: "trash",
                    tint: .red,
                    action: onDelete,
                    accessibilityLabel: "Delete word"
                )
                Spacer()
                TintedCircleButton(
                    systemImage: "speaker.wave.2.fill",
                    tint: DS.Color.ink,
                    action: { SpeechService.shared.speak(word.exampleSentence) },
                    accessibilityLabel: "Play example sentence"
                )
                Spacer()
                TintedCircleButton(
                    systemImage: knowsWord ? "questionmark" : "checkmark",
                    tint: knowsWord ? .orange : .green,
                    action: { onRate(knowsWord ? .again : .good) },
                    accessibilityLabel: knowsWord ? "Move back to learning" : "Mark as known"
                )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }
}

#Preview {
    NavigationStack { MyWordsView() }
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self], inMemory: true)
}
