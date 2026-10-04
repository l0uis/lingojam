import SwiftUI
import SwiftData

/// Today's story for `language`, generated on demand if the background run
/// hasn't already written it.
struct TodayStoryScreen: View {
    let language: TargetLanguage

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var story: DailyStory?
    @State private var didFail = false

    var body: some View {
        Group {
            if let story {
                StoryView(story: story)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if didFail {
                            Text("Dr Tusk couldn't finish today's story.")
                                .font(.sniglet(.headline))
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.primary)
                                .frame(maxWidth: 240)
                        } else {
                            ProgressView()
                            Text("Dr Tusk is writing your story…")
                                .font(.sniglet(.headline))
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Color.paper.ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        didFail = false
        story = try? await DailyStoryService.ensureTodayStory(context: context, language: language)
        didFail = story == nil
    }
}

/// One of Dr Tusk's stories: narration with a sentence highlight, tappable
/// words, the new words highlighted, a couple of questions, and an end
/// screen that leads into a retell call.
struct StoryView: View {
    @Bindable var story: DailyStory

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var narrator = StoryNarrator()
    @State private var reading: StoryReading?
    @State private var selectedWord: SelectedWord?
    @State private var lookedUpKeys: Set<String> = []
    /// Question index → chosen option index.
    @State private var answers: [Int: Int] = [:]
    @State private var isShowingEnd = false

    private static let endCardID = "story-end"
    /// Highlighter-pen yellow behind the sentence being read.
    private static let sentenceMarker = Color(red: 1.0, green: 0.86, blue: 0.35).opacity(0.55)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        narrationBar
                        storyText
                        if !story.questions.isEmpty { questions }
                        if isShowingEnd {
                            endCard.id(Self.endCardID)
                        } else {
                            Button("Finish story") { finish(proxy: proxy) }
                                .buttonStyle(.primary)
                                .disabled(answers.count < story.questions.count)
                        }
                        #if DEBUG
                        StoryDiagnostics(story: story)
                        #endif
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .background(DS.Color.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if story.openedAt == nil {
                story.openedAt = .now
                try? context.save()
            }
            StoryScheduler.cancelNotification(for: story)
            isShowingEnd = story.isCompleted
            reading = await StoryReading.make(story: story, context: context)
        }
        .onDisappear { narrator.stop() }
        .sheet(item: $selectedWord) { selection in
            StoryWordSheet(surface: selection.surface, word: selection.word, language: story.language ?? .spanish)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DrTuskAvatar(size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dr Tusk")
                        .font(.sniglet(.subheadline))
                    Text(StoryTimestamp.string(for: story.createdAt))
                        .font(.sniglet(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Text(story.title)
                .font(.gochiHand(size: 32, relativeTo: .largeTitle))
                .foregroundStyle(DS.Color.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Narration

    private var narrationBar: some View {
        HStack(spacing: 14) {
            Button {
                Task { await narrator.togglePlayback(for: story, sentences: reading?.sentences ?? []) }
            } label: {
                Group {
                    if narrator.state == .loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: narrator.isPlaying ? "pause.fill" : "play.fill")
                            .font(.sniglet(.title3))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.Color.ink))
            }
            .buttonStyle(.plain)
            .disabled(reading == nil)
            .accessibilityLabel(narrator.isPlaying ? Text("Pause story") : Text("Play story"))

            VStack(alignment: .leading, spacing: 6) {
                Text(narrationStatus)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(narrator.state == .failed ? Color.red : Color.primary)
                ProgressView(value: narrator.progress)
                    .tint(DS.Color.ink)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(.white.opacity(0.7)))
    }

    private var narrationStatus: LocalizedStringKey {
        switch narrator.state {
        case .idle, .finished: "Listen to Dr Tusk"
        case .loading: "Getting Dr Tusk's voice ready…"
        case .playing: "Dr Tusk is reading"
        case .paused: "Paused"
        case .failed: "Couldn't load Dr Tusk's voice. Tap to try again."
        }
    }

    // MARK: Story text

    /// One block per sentence, so a new sentence never looks like a wrapped
    /// line. The sentence being read sits on a highlighter-yellow bar — the
    /// only colour on the text. Every word is a link; new words are underlined.
    private var storyText: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lines = sentenceLines {
                ForEach(lines, id: \.index) { line in
                    Text(line.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(line.index == narrator.currentSentence ? Self.sentenceMarker : .clear)
                        )
                }
            } else {
                Text(story.text).padding(.horizontal, 8)
            }
        }
        .font(.sniglet(.title3))
        .lineSpacing(6)
        .tint(Color.primary)
        .textSelection(.disabled)
        .padding(.horizontal, -8)   // keep the text aligned with the title; the bar overhangs
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == StoryWordLink.scheme,
                  let index = Int(url.host() ?? ""),
                  let reading, reading.tokens.indices.contains(index) else { return .discarded }
            open(reading.tokens[index])
            return .handled
        })
        .accessibilityHint(Text("Words are links. Use the Links rotor to look one up."))
        // The highlight just moves on — no animation between sentences.
        .transaction { $0.animation = nil }
    }

    /// Each sentence as attributed text: every word a link, new words underlined.
    private var sentenceLines: [(index: Int, text: AttributedString)]? {
        guard let reading, !reading.sentences.isEmpty else { return nil }
        let text = story.text
        return reading.sentences.enumerated().compactMap { sentenceIndex, sentence in
            let range = Self.trimmed(sentence, in: text)
            guard !range.isEmpty else { return nil }
            var line = AttributedString(text[range])
            for (tokenIndex, token) in reading.tokens.enumerated()
            where token.role != .number && token.role != .name
                && range.contains(token.range.lowerBound) && token.range.upperBound <= range.upperBound {
                let lower = line.index(line.startIndex, offsetByCharacters: text.distance(from: range.lowerBound, to: token.range.lowerBound))
                let upper = line.index(lower, offsetByCharacters: text.distance(from: token.range.lowerBound, to: token.range.upperBound))
                line[lower..<upper].link = StoryWordLink.url(for: tokenIndex)
                if token.newWord != nil {
                    line[lower..<upper].underlineStyle = .single
                }
            }
            return (sentenceIndex, line)
        }
    }

    /// A sentence range without its surrounding whitespace.
    private static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        return lower..<upper
    }

    private func open(_ token: StoryReading.Token) {
        // Looking a word up shouldn't race the narration past the sentence.
        if narrator.isPlaying { narrator.pause() }
        lookedUpKeys.formUnion(token.keys)
        selectedWord = SelectedWord(surface: token.surface, word: reading?.word(for: token))
    }

    // MARK: Questions

    private var questions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Did you follow?").sectionHeaderStyle()
            ForEach(Array(story.questions.enumerated()), id: \.offset) { index, question in
                StoryQuestionView(question: question, chosen: answers[index]) { option in
                    answers[index] = option
                }
            }
        }
    }

    private var correctAnswers: Int {
        story.questions.enumerated().filter { answers[$0.offset] == $0.element.answerIndex }.count
    }

    // MARK: End

    private func finish(proxy: ScrollViewProxy) {
        narrator.stop()
        story.completedAt = .now
        if !story.questions.isEmpty {
            story.quizCorrect = correctAnswers
            story.quizTotal = story.questions.count
        }
        try? context.save()
        withAnimation(.snappy) { isShowingEnd = true }
        Task { @MainActor in
            // Let the card lay out before scrolling to it.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo(Self.endCardID, anchor: .top) }
        }
    }

    private var understood: Double {
        guard let reading else { return story.coverage }
        let unknownKeys = Set((story.coverageReport?.unknownLemmas ?? []).map {
            StoryVocabularyChecker.fold($0, languageCode: reading.languageCode)
        })
        return StoryComprehension.understood(tokens: reading.tokens, unknownKeys: unknownKeys, lookedUpKeys: lookedUpKeys)
    }

    private var endCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You understood \(understood.formatted(.percent.precision(.fractionLength(0)))) of this story")
                .font(.gochiHand(size: 28, relativeTo: .title))
                .foregroundStyle(DS.Color.ink)
            if let total = story.quizTotal, total > 0 {
                Text("\(story.quizCorrect ?? 0) of \(total) questions right")
                    .font(.sniglet(.headline))
            }
            if !story.highlightedWords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New words").sectionHeaderStyle()
                    Text(story.highlightedWords.joined(separator: " · "))
                        .font(.sniglet(.title3))
                        .bold()
                }
            }
            Button {
                retell()
            } label: {
                Label("Retell it to Dr Tusk", systemImage: "phone.fill")
            }
            .buttonStyle(.primary)
            Text("Tell him the story in your own words. He'll listen for the new ones.")
                .font(.sniglet(.footnote))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: DS.Radius.surface).fill(.white.opacity(0.8)))
    }

    private func retell() {
        let words = reading?.words(forLemmas: story.highlightedWords) ?? []
        let seed = CallSeed(
            wordIDs: words.map(\.id),
            storyContext: StoryRetell.context(for: story)
        )
        narrator.stop()
        dismiss()
        IncomingCallCoordinator.shared.requestOutgoing(seed: seed)
    }
}

// MARK: - Pieces

/// What a tap on a story word opens.
private struct SelectedWord: Identifiable {
    let id = UUID()
    let surface: String
    let word: VocabularyWord?
}

/// `wordrus-story-word://<token index>` — routed by the story text's
/// `openURL` handler, never by the system.
private enum StoryWordLink {
    static let scheme = "wordrus-story-word"
    static func url(for index: Int) -> URL? { URL(string: "\(scheme)://\(index)") }
}

enum StoryRetell {
    /// Brain instructions for the retell call (English, like the rest of the
    /// brain prompts).
    static func context(for story: DailyStory) -> String {
        let words = story.highlightedWords.joined(separator: ", ")
        return """
        This call is about the story you (Dr Tusk) told the learner today, "\(story.title)". \
        What happened: \(story.episodeSummary) \
        Ask them to retell it to you in their own words, one bit at a time. Be a curious, \
        slightly forgetful listener: ask what happened next, and gently nudge them to use \
        these new words from the story: \(words).
        """
    }
}

/// "Today, 16:24" / "Yesterday, 08:10" / "Thu 1 Oct, 09:30" — like Messages.
enum StoryTimestamp {
    static func string(for date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// Dr Tusk's head, cropped from the full-length artwork (543×990) like a
/// contact avatar.
struct DrTuskAvatar: View {
    var size: CGFloat = 44

    var body: some View {
        Image("walrus")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 0.86, height: size * 0.86 * 990 / 543)
            .offset(y: size * 0.11)
            .frame(width: size, height: size, alignment: .top)
            .background(DS.Color.paperShade)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

private struct StoryQuestionView: View {
    let question: StoryQuestion
    let chosen: Int?
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.sniglet(.headline))
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    guard chosen == nil else { return }
                    onChoose(index)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: index))
                            .foregroundStyle(tint(for: index))
                        Text(option)
                            .font(.sniglet(.body))
                            .foregroundStyle(Color.primary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(.white.opacity(0.7)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Not `.disabled`: that would grey out the answer the learner
                // is meant to be reading.
                .allowsHitTesting(chosen == nil)
                .accessibilityLabel(accessibilityLabel(for: index, option: option))
            }
            if let chosen {
                Text(chosen == question.answerIndex
                     ? String(localized: "Correct!")
                     : String(localized: "Not quite — it was “\(question.options[question.answerIndex])”."))
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for index: Int) -> String {
        guard let chosen else { return "circle" }
        if index == question.answerIndex { return "checkmark.circle.fill" }
        return index == chosen ? "xmark.circle.fill" : "circle"
    }

    private func tint(for index: Int) -> Color {
        guard let chosen else { return .secondary }
        if index == question.answerIndex { return .green }
        return index == chosen ? .red : .secondary
    }

    private func accessibilityLabel(for index: Int, option: String) -> String {
        guard let chosen else { return option }
        if index == question.answerIndex { return String(localized: "\(option), correct answer") }
        if index == chosen { return String(localized: "\(option), your answer, wrong") }
        return option
    }
}

#if DEBUG
/// Vocabulary-check details while the generation brains are being tuned.
private struct StoryDiagnostics: View {
    let story: DailyStory

    var body: some View {
        let report = story.coverageReport
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Brain: \(story.brainRaw) · attempts: \(story.attempts) · \(story.levelRaw) · topic: \(story.topic)")
                Text(verbatim: "Coverage: \(story.coverage.formatted(.percent.precision(.fractionLength(1)))) · words: \(report?.wordCount ?? 0) · passed: \(report?.passed == true)")
                Text(verbatim: "New: \(story.newWords.joined(separator: ", ")) · extra: \(story.extraWords.joined(separator: ", "))")
                Text(verbatim: "Unknown: \(report?.unknownLemmas.joined(separator: ", ") ?? "–")")
                Text(verbatim: "Episode → \(story.episodeSummary)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: "Diagnostics")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}
#endif
