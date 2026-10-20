import SwiftUI
import SwiftData

/// One of Dr Tusk's stories, as a front page of *The Antarctic Times*:
/// narration with a sentence highlight, tappable words, the new words
/// underlined. Ends with "Take quiz", which hands over to `StoryQuizSheet`
/// (see `storySheet(item:)`).
struct StoryView: View {
    @Bindable var story: DailyStory
    /// Close the article and open its quiz.
    let onTakeQuiz: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var narrator = StoryNarrator()
    @State private var entitlements = Entitlements.shared
    @State private var reading: StoryReading?
    @State private var selectedWord: SelectedWord?
    /// Whether the page scrolls along with the narration.
    @State private var followsNarration = true
    /// The word that was just tapped, and how much it's scaled up right now.
    @State private var bouncingToken: Int?
    @State private var bounceScale = 1.0
    /// Highlighter-pen yellow behind the sentence being read.
    private static let sentenceMarker = Color(red: 1.0, green: 0.86, blue: 0.35).opacity(0.55)

    private static func sentenceID(_ index: Int) -> String { "sentence-\(index)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Masthead(name: Newsprint.name(for: story.language), date: story.createdAt, issue: Newsprint.issueNumber(of: story, in: context))
                    header
                    NewsRule()
                    storyText
                    Text(verbatim: "■")
                        .font(.system(size: 9))
                        .foregroundStyle(Newsprint.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                    quizButton
                    #if DEBUG
                    StoryDiagnostics(story: story)
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)   // clear of the grabber
                .padding(.bottom, 24)
            }
            // The play button floats over the page; the inset lets the end
            // of the article scroll clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) { playButton }
            // Keep the sentence being read in view — until the learner scrolls
            // themselves; pressing play again picks the page back up.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsNarration = false }
            }
            .onChange(of: narrator.currentSentence) { _, sentence in
                guard followsNarration, let sentence else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(Self.sentenceID(sentence), anchor: UnitPoint(x: 0.5, y: 0.4))
                }
            }
        }
        .background(Newsprint.paper.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task {
            if story.openedAt == nil {
                story.openedAt = .now
                try? context.save()
            }
            StoryScheduler.cancelNotification(for: story)
            reading = await StoryReading.make(story: story, context: context)
        }
        .onDisappear { narrator.stop() }
        .sheet(item: $selectedWord) { selection in
            StoryWordSheet(surface: selection.surface, word: selection.word, language: story.language ?? .spanish)
        }
    }

    // MARK: Header

    /// Section kicker, headline and byline — the top of the article.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !story.topic.isEmpty {
                Text(story.topic.uppercased())
                    .font(.system(.caption, design: .serif, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Newsprint.kicker)
            }

            Text(story.title)
                .font(.system(size: 34, weight: .bold, design: .serif))
                .lineSpacing(-2)
                .foregroundStyle(Newsprint.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                DrTuskAvatar(size: 34)
                    .grayscale(1)
                    .contrast(1.15)
                VStack(alignment: .leading, spacing: 1) {
                    Text("By Dr Tusk")
                        .font(.system(.subheadline, design: .serif, weight: .semibold))
                        .foregroundStyle(Newsprint.ink)
                    Text("Chief Correspondent")
                        .font(.system(.caption, design: .serif))
                        .italic()
                        .foregroundStyle(Newsprint.byline)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Narration

    /// "Listen to this article", like a news app: a strip between rules.
    /// Big play button pinned bottom centre, its ring filling as Dr Tusk
    /// reads. Sits on a fade so the text slides softly under it.
    private var playButton: some View {
        VStack(spacing: 10) {
            if narrator.state == .failed {
                Text("Couldn't load Dr Tusk's voice. Tap to try again.")
                    .font(.system(.footnote, design: .serif, weight: .medium))
                    .foregroundStyle(Newsprint.paper)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Newsprint.kicker))
                    .transition(.opacity)
            }
            // Speed button to the right; an empty twin on the left keeps
            // the play button centred.
            HStack(spacing: 20) {
                Color.clear.frame(width: Self.speedButtonSize, height: Self.speedButtonSize)
                playToggle
                if entitlements.isPro {
                    speedButton
                } else {
                    Color.clear.frame(width: Self.speedButtonSize, height: Self.speedButtonSize)
                }
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Newsprint.paper.opacity(0), Newsprint.paper], startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        )
        .animation(.snappy, value: narrator.state == .failed)
    }

    private var playToggle: some View {
        Button {
            if !narrator.isPlaying { followsNarration = true }
            Task { await narrator.togglePlayback(for: story, sentences: reading?.sentences ?? []) }
        } label: {
            ZStack {
                Circle()
                    .fill(Newsprint.ink)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                Circle()
                    .trim(from: 0, to: narrator.progress)
                    .stroke(Newsprint.paper.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                Group {
                    if narrator.state == .loading {
                        ProgressView().tint(Newsprint.paper).controlSize(.large)
                    } else {
                        Image(systemName: playSymbol)
                            .font(.system(size: 28, weight: .semibold))
                            // Optical centre: a play triangle sits left.
                            .offset(x: playSymbol == "play.fill" ? 2 : 0)
                    }
                }
                .foregroundStyle(Newsprint.paper)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(reading == nil)
        .accessibilityLabel(playLabel)
        .accessibilityValue(Text(narrator.progress.formatted(.percent.precision(.fractionLength(0)))))
    }

    private static let speedButtonSize: CGFloat = 48

    /// Speed options behind a speedometer, like the word cards; a pick
    /// retimes the sentence being read straight away.
    private var speedButton: some View {
        VoiceSpeedMenu(source: "story", onChange: { _ in narrator.applyVoiceSpeed() }) {
            Image(systemName: "speedometer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Newsprint.ink)
                .frame(width: Self.speedButtonSize, height: Self.speedButtonSize)
                .background(Circle().strokeBorder(Newsprint.ink, lineWidth: 1.5))
                .contentShape(Circle())
        }
    }

    private var playSymbol: String {
        switch narrator.state {
        case .playing: "pause.fill"
        case .failed: "arrow.clockwise"
        default: "play.fill"
        }
    }

    private var playLabel: Text {
        switch narrator.state {
        case .playing: Text("Pause story")
        case .failed: Text("Try loading Dr Tusk's voice again")
        case .loading: Text("Getting Dr Tusk's voice ready…")
        default: Text("Play story")
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
                    Self.text(for: line.segments)
                        .textRenderer(WordBounceRenderer(tokenIndex: bouncingToken, scale: bounceScale))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(line.index == narrator.currentSentence ? Self.sentenceMarker : .clear)
                        )
                        // The highlight just moves on — no animation between sentences.
                        .transaction(value: narrator.currentSentence) { $0.animation = nil }
                        .id(Self.sentenceID(line.index))
                }
            } else {
                Text(story.text).padding(.horizontal, 8)
            }
        }
        .font(.system(.title3, design: .serif))
        .lineSpacing(7)
        .foregroundStyle(Newsprint.ink)
        .tint(Newsprint.ink)
        .textSelection(.disabled)
        .padding(.horizontal, -8)   // keep the text aligned with the title; the bar overhangs
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == StoryWordLink.scheme,
                  let index = Int(url.host() ?? ""),
                  let reading, reading.tokens.indices.contains(index) else { return .discarded }
            open(reading.tokens[index], at: index)
            return .handled
        })
        .accessibilityHint(Text("Words are links. Use the Links rotor to look one up."))
    }

    /// A run of a sentence: a word (a link, underlined if it's new, marked
    /// with its token index so it can bounce) or the text between words.
    private struct Segment {
        let text: AttributedString
        let tokenIndex: Int?
    }

    /// Each sentence split into word and in-between segments.
    private var sentenceLines: [(index: Int, segments: [Segment])]? {
        guard let reading, !reading.sentences.isEmpty else { return nil }
        let text = story.text
        return reading.sentences.enumerated().compactMap { sentenceIndex, sentence in
            let range = Self.trimmed(sentence, in: text)
            guard !range.isEmpty else { return nil }
            var segments: [Segment] = []
            var cursor = range.lowerBound
            for (tokenIndex, token) in reading.tokens.enumerated()
            where token.role != .number && token.role != .name
                && token.range.lowerBound >= cursor && token.range.upperBound <= range.upperBound {
                if cursor < token.range.lowerBound {
                    segments.append(Segment(text: AttributedString(text[cursor..<token.range.lowerBound]), tokenIndex: nil))
                }
                var word = AttributedString(text[token.range])
                word.link = StoryWordLink.url(for: tokenIndex)
                if token.newWord != nil { word.underlineStyle = .single }
                segments.append(Segment(text: word, tokenIndex: tokenIndex))
                cursor = token.range.upperBound
            }
            if cursor < range.upperBound {
                segments.append(Segment(text: AttributedString(text[cursor..<range.upperBound]), tokenIndex: nil))
            }
            return (sentenceIndex, segments)
        }
    }

    /// One `Text` for the sentence, so it wraps like a paragraph; words carry
    /// `StoryWordRun` for `WordBounceRenderer`.
    private static func text(for segments: [Segment]) -> Text {
        segments.reduce(Text(verbatim: "")) { sentence, segment in
            let piece = Text(segment.text)
            guard let tokenIndex = segment.tokenIndex else { return sentence + piece }
            return sentence + piece.customAttribute(StoryWordRun(tokenIndex: tokenIndex))
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

    /// A tap on a word: a light tap, the word pops up and settles back with
    /// a little bounce, and its sheet opens as it settles.
    private func open(_ token: StoryReading.Token, at index: Int) {
        // Looking a word up shouldn't race the narration past the sentence.
        if narrator.isPlaying { narrator.pause() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        bouncingToken = index
        bounceScale = 1
        withAnimation(.snappy(duration: 0.12)) {
            bounceScale = 1.15
        } completion: {
            withAnimation(.spring(duration: 0.4, bounce: 0.6)) { bounceScale = 1 }
            selectedWord = SelectedWord(surface: token.surface, word: reading?.word(for: token))
        }
    }

    // MARK: Quiz

    /// The article's last word: off to the quiz. A story without questions
    /// just finishes here.
    @ViewBuilder
    private var quizButton: some View {
        if story.questions.isEmpty {
            Button("Done") {
                if story.completedAt == nil {
                    story.completedAt = .now
                    try? context.save()
                }
                dismiss()
            }
            .buttonStyle(.primary)
        } else {
            Button(story.isCompleted ? "See quiz results" : "Take quiz") { onTakeQuiz() }
                .buttonStyle(.primary)
        }
    }
}

// MARK: - Pieces

/// What a tap on a story word opens.
private struct SelectedWord: Identifiable {
    let id = UUID()
    let surface: String
    let word: VocabularyWord?
}

/// Marks a word's run in the story text so `WordBounceRenderer` can find it.
private struct StoryWordRun: TextAttribute {
    let tokenIndex: Int
}

/// Draws the story text as usual, except the tapped word, which is scaled
/// about its own centre — line layout never moves.
private struct WordBounceRenderer: TextRenderer {
    var tokenIndex: Int?
    var scale: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let tokenIndex, scale != 1, run[StoryWordRun.self]?.tokenIndex == tokenIndex else {
                    context.draw(run)
                    continue
                }
                let bounds = run.typographicBounds.rect
                var scaled = context
                scaled.translateBy(x: bounds.midX, y: bounds.midY)
                scaled.scaleBy(x: scale, y: scale)
                scaled.translateBy(x: -bounds.midX, y: -bounds.midY)
                scaled.draw(run)
            }
        }
    }
}

/// `wordrus-story-word://<token index>` — routed by the story text's
/// `openURL` handler, never by the system.
private enum StoryWordLink {
    static let scheme = "wordrus-story-word"
    static func url(for index: Int) -> URL? { URL(string: "\(scheme)://\(index)") }
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

// MARK: - The Antarctic Times

/// The story screen's newspaper look: Dr Tusk's stories are front pages of
/// *The Antarctic Times*. Newsprint stays light — the app is light-only.
enum Newsprint {
    /// Warm, slightly grey newsprint — a touch duller than `DS.Color.paper`.
    static let paper = Color(red: 0xF4 / 255.0, green: 0xEF / 255.0, blue: 0xE4 / 255.0)
    /// Printer's black, warmed so it doesn't buzz against the paper.
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let byline = Color(red: 0.36, green: 0.34, blue: 0.31)
    /// Spot colour for section kickers, like a paper's red.
    static let kicker = Color(red: 0.70, green: 0.13, blue: 0.13)

    /// The paper's name in the language the story is written in — part of
    /// the immersion, so it isn't localised into the learner's own language.
    static func name(for language: TargetLanguage?) -> String {
        switch language {
        case .spanish: "El Antártico"
        case .french: "L’Antarctique"
        case .italian: "L’Antartico"
        case .german: "Die Antarktis-Zeitung"
        case .english, nil: "The Antarctic Times"
        }
    }

    /// A story's issue number: its place among the learner's stories in its
    /// language, like `StoryRequest.episodeNumber`.
    static func issueNumber(of story: DailyStory, in context: ModelContext) -> Int {
        let language = story.languageRaw
        let createdAt = story.createdAt
        let earlier = (try? context.fetchCount(FetchDescriptor<DailyStory>(predicate: #Predicate {
            $0.languageRaw == language && $0.createdAt < createdAt
        }))) ?? 0
        return earlier + 1
    }
}

/// A printed rule across the column.
private struct NewsRule: View {
    var weight: CGFloat = 1

    var body: some View {
        Rectangle()
            .fill(Newsprint.ink)
            .frame(height: weight)
            .accessibilityHidden(true)
    }
}

/// The paper's name (`Newsprint.name(for:)`) with its motto, between a heavy rule and a double
/// rule, and the folio line: volume and issue, date, price.
private struct Masthead: View {
    let name: String
    let date: Date
    let issue: Int

    var body: some View {
        VStack(spacing: 8) {
            NewsRule(weight: 3)
            Text(verbatim: name)
                .font(.system(size: 34, weight: .black, design: .serif))
                .textCase(.uppercase)
                .tracking(-0.5)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(Newsprint.ink)
                .accessibilityAddTraits(.isHeader)
            Text("“All the news that’s fit to freeze”")
                .font(.system(.caption, design: .serif))
                .italic()
                .foregroundStyle(Newsprint.byline)
            VStack(spacing: 2) {
                NewsRule()
                NewsRule(weight: 2)
            }
            HStack {
                Text("No. \(issue)")
                Spacer()
                Text(date.formatted(date: .complete, time: .omitted))
                Spacer()
                Text("One sardine")
            }
            .font(.system(.caption2, design: .serif, weight: .semibold))
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Newsprint.ink)
            NewsRule()
        }
        .accessibilityElement(children: .combine)
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
