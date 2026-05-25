import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct JamView: View {
    @Environment(\.modelContext) private var context
    @Query private var allProgress: [LearningProgress]
    @Query(sort: \VocabularyWord.rank) private var allWords: [VocabularyWord]

    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage(DeckConstants.selectedCEFRLevelDefaultsKey) private var selectedCEFRLevel: String = DeckConstants.defaultCEFRLevel
    @AppStorage("jam.soundEnabled") private var soundEnabled: Bool = true

    @State private var queue: [VocabularyWord] = []
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut: Bool = false
    @State private var releaseRating: ReviewRating? = nil
    @State private var releaseProgress: Double = 0

    private let swipeThreshold: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.paper.ignoresSafeArea()

                if queue.isEmpty {
                    emptyState
                } else {
                    ZStack(alignment: .top) {
                        Image("walrus")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 180)
                            .padding(.top, 8)
                            .allowsHitTesting(false)

                        cardStack(in: geo.size)
                            .padding(.top, 130)
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .deckLanguageToolbar()
        .onAppear {
            if selectedCEFRLevel == DeckConstants.allLevelsValue {
                selectedCEFRLevel = DeckConstants.defaultCEFRLevel
            }
            rebuildQueueIfNeeded()
            applyPendingDeepLink()
        }
        .onChange(of: allWords.count) { _, _ in
            queue = []
            rebuildQueueIfNeeded()
        }
        .onChange(of: selectedDeckSlug) { _, _ in
            queue = []
            rebuildQueueIfNeeded()
            DailyWordService.refresh(context: context)
        }
        .onChange(of: selectedCEFRLevel) { _, _ in
            queue = []
            rebuildQueueIfNeeded()
            DailyWordService.refresh(context: context)
        }
        .onChange(of: queue.first?.id) { _, newID in
            guard let id = newID, let word = queue.first, word.id == id else {
                DailyWordService.refresh(context: context)
                return
            }
            if soundEnabled {
                SpeechService.shared.speak(word.exampleSentence)
            }
            DailyWordService.setActiveWord(word, progress: allProgress.first { $0.wordID == id })
        }
    }

    private var dragProgress: CGFloat {
        min(1, abs(dragOffset.width) / swipeThreshold)
    }

    @ViewBuilder
    private func cardStack(in size: CGSize) -> some View {
        ZStack {
            if queue.count > 2 {
                upcomingCardView(word: queue[2], depth: 2)
            }
            if queue.count > 1 {
                upcomingCardView(word: queue[1], depth: 1)
            }

            HStack {
                dontKnowOverlay
                Spacer()
                knowOverlay
            }
            .padding(.horizontal, 32)
            .allowsHitTesting(false)

            if let current = queue.first {
                cardView(word: current)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                    .gesture(dragGesture(cardWidth: size.width))
                    .id(current.id)
                    .transition(.identity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    private func upcomingCardView(word: VocabularyWord, depth: Int) -> some View {
        let effectiveDepth = CGFloat(depth) - dragProgress
        return cardView(word: word)
            .scaleEffect(1.0 - 0.05 * effectiveDepth)
            .offset(y: 18 * effectiveDepth)
            .allowsHitTesting(false)
            .id(word.id)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                    removal: .identity
                )
            )
    }

    private func cardView(word: VocabularyWord) -> some View {
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

            VStack(alignment: .leading, spacing: 6) {
                Text(word.exampleSentence)
                    .font(.sniglet(.title3))
                    .italic()
                if let translation = LocaleService.exampleTranslation(for: word) {
                    Text(translation)
                        .font(.sniglet(.title3))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    soundEnabled.toggle()
                    playSoundToggleHaptic()
                    if soundEnabled {
                        SpeechService.shared.speak(word.exampleSentence)
                    } else {
                        SpeechService.shared.stop()
                    }
                } label: {
                    Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.sniglet(.title3))
                        .foregroundStyle(soundEnabled ? DS.Color.ink : Color.gray)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle().fill(
                                soundEnabled
                                    ? DS.Color.ink.opacity(0.15)
                                    : Color.gray.opacity(0.15)
                            )
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(soundEnabled ? "Mute audio" : "Unmute audio")
                Spacer()
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
    }

    private var knowOverlay: some View {
        let progress: Double = {
            if releaseRating == .good { return releaseProgress }
            return dragOffset.width < 0 ? min(1, Double(-dragOffset.width) / Double(swipeThreshold)) : 0
        }()
        return overlayBadge(systemImage: "checkmark.circle.fill", tint: .green, progress: progress)
    }

    private var dontKnowOverlay: some View {
        let progress: Double = {
            if releaseRating == .again { return releaseProgress }
            return dragOffset.width > 0 ? min(1, Double(dragOffset.width) / Double(swipeThreshold)) : 0
        }()
        return overlayBadge(systemImage: "questionmark.circle.fill", tint: DS.Color.ink, progress: progress)
    }

    private func overlayBadge(systemImage: String, tint: Color, progress: Double) -> some View {
        Image(systemName: systemImage)
            .font(.sniglet(size: 84, weight: .bold))
            .foregroundStyle(tint)
            .padding(10)
            .background(Circle().fill(.white))
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(min(1, progress))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.sniglet(size: 48))
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.sniglet(.title2, weight: .bold))
            if let next = nextDueAfterToday() {
                Text("Next review \(next, style: .relative)")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            } else {
                Text("Come back tomorrow for more practice.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private func dragGesture(cardWidth: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnimatingOut else { return }
                dragOffset = CGSize(width: value.translation.width, height: 0)
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                if value.translation.width < -swipeThreshold {
                    commit(rating: .good, toLeftBy: cardWidth)
                } else if value.translation.width > swipeThreshold {
                    commit(rating: .again, toLeftBy: -cardWidth)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func commit(rating: ReviewRating, toLeftBy travel: CGFloat) {
        guard let word = queue.first else { return }
        isAnimatingOut = true

        // Snapshot the icon at full intensity so we can animate it out
        // independently of the card's dragOffset.
        var snapshot = Transaction()
        snapshot.disablesAnimations = true
        withTransaction(snapshot) {
            releaseRating = rating
            releaseProgress = 1.0
        }

        // Card flies off.
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: -travel * 1.6, height: 0)
        }

        // Icon pops slightly bigger then shrinks out.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            releaseProgress = 1.3
        }
        withAnimation(.easeIn(duration: 0.28).delay(0.08)) {
            releaseProgress = 0
        }

        record(rating: rating, for: word)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                dragOffset = .zero
                releaseRating = nil
                releaseProgress = 0
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                _ = queue.removeFirst()
                refillQueue()
            }
            isAnimatingOut = false
            playLightHaptic()
        }
    }

    private func playLightHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func playSoundToggleHaptic() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    private func record(rating: ReviewRating, for word: VocabularyWord) {
        let existing = allProgress.first { $0.wordID == word.id }
        let progress = existing ?? LearningProgress(wordID: word.id)
        if existing == nil { context.insert(progress) }
        let intervalBefore = progress.intervalDays
        let result = SRSScheduler.next(progress: progress, rating: rating)
        progress.state = result.state
        progress.easeFactor = result.easeFactor
        progress.intervalDays = result.intervalDays
        progress.repetitions = result.repetitions
        progress.lapses = result.lapses
        progress.dueDate = result.dueDate
        progress.lastReviewedAt = result.lastReviewedAt
        let log = ReviewLog(
            wordID: word.id,
            reviewedAt: result.lastReviewedAt,
            rating: rating,
            intervalBeforeDays: intervalBefore,
            intervalAfterDays: result.intervalDays
        )
        context.insert(log)
        try? context.save()
        EngagementTracker.shared.recordCardReview()
    }

    private func rebuildQueueIfNeeded() {
        guard queue.isEmpty else { return }
        refillQueue()
        applyPendingDeepLink()
    }

    private func refillQueue() {
        let targetSize = 5
        var working = queue
        let presentIDs = Set(working.map(\.id))
        let candidates = nextWords(excluding: presentIDs, limit: targetSize - working.count)
        working.append(contentsOf: candidates)
        queue = working
    }

    private func applyPendingDeepLink() {
        guard let pendingID = DeepLink.consumePendingWordID() else { return }
        if queue.first?.id == pendingID { return }
        if let index = queue.firstIndex(where: { $0.id == pendingID }) {
            let word = queue.remove(at: index)
            queue.insert(word, at: 0)
        } else if let word = allWords.first(where: { $0.id == pendingID }) {
            queue.insert(word, at: 0)
        }
    }

    private func nextWords(excluding excluded: Set<String>, limit: Int) -> [VocabularyWord] {
        guard limit > 0 else { return [] }
        let now = Date.now
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })
        let pool = wordsInSelectedDeck()

        // Due pool: bucket by day so the most overdue still come first, but
        // shuffle within each day to avoid showing frequency-adjacent or
        // topic-adjacent reviews back-to-back.
        let dueWithDates = pool.compactMap { word -> (VocabularyWord, Date)? in
            guard !excluded.contains(word.id),
                  let progress = progressByID[word.id],
                  progress.dueDate <= now
            else { return nil }
            return (word, progress.dueDate)
        }
        let cal = Calendar.current
        let byDay = Dictionary(grouping: dueWithDates) { cal.startOfDay(for: $0.1) }
        let dueWords = byDay.keys.sorted().flatMap { day in
            (byDay[day] ?? []).map(\.0).shuffled()
        }

        // New pool: shuffle so frequency-adjacent lemmas don't cluster.
        let newWords = pool
            .filter { !excluded.contains($0.id) && progressByID[$0.id] == nil }
            .shuffled()

        return Array((dueWords + newWords).prefix(limit))
    }

    private func wordsInSelectedDeck() -> [VocabularyWord] {
        let deckSlug = selectedDeckSlug
        let level = selectedCEFRLevel
        return allWords.filter { word in
            if deckSlug != DeckConstants.allSlug, !word.deckSlugs.contains(deckSlug) {
                return false
            }
            if level != DeckConstants.allLevelsValue, word.cefrLevel != level {
                return false
            }
            return true
        }
    }

    private func nextDueAfterToday() -> Date? {
        let now = Date.now
        return allProgress
            .filter { $0.dueDate > now }
            .min { $0.dueDate < $1.dueDate }?
            .dueDate
    }

}

#Preview {
    NavigationStack { JamView() }
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
