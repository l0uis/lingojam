import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

private extension Font {
    /// Shared title font for every onboarding step. Kept in one place so the
    /// whole flow stays visually consistent and the size is trivial to tune.
    /// Deliberately smaller than a hero largeTitle so long prompts (e.g.
    /// "Which topics are you interested in?") don't sprawl to three lines or
    /// truncate on smaller screens.
    static let onboardingTitle = Font.gochiHand(size: 34, relativeTo: .title)
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case language
    case walrusIntro
    case name
    case customizeIntro
    case dailyGoal
    case notifications
    case goalSetup
    case topics
    case exampleCard
    case vocabularyLevel
    case testIntro
    case beginnerWords
    case intermediateWords
    case advancedWords
    case finalPitch
}

struct OnboardingFlow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var state = OnboardingState()
    @State private var step: OnboardingStep = .welcome
    /// Which way the step transition slides; flipped just before stepping
    /// back so the outgoing screen leaves to the right.
    @State private var isGoingBack = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                // Hidden on the screens with a full-bleed panel at the top.
                if ![.welcome, .walrusIntro, .testIntro, .finalPitch].contains(step) {
                    progressBar
                        // Clears the back button overlaid on the leading edge.
                        .padding(.leading, 64)
                        .padding(.trailing, 24)
                        .padding(.top, 16)
                }

                Group {
                    switch step {
                    case .welcome: WelcomeStep(onContinue: advance)
                    case .language: LanguageStep(native: $state.nativeLanguage, selection: $state.targetLanguage, onContinue: advance)
                    case .walrusIntro: WalrusIntroStep(onContinue: advance)
                    case .name: NameStep(name: $state.displayName, onContinue: advance)
                    case .customizeIntro: CustomizeIntroStep(name: state.displayName, onContinue: advance)
                    case .dailyGoal: DailyGoalStep(size: $state.dailySetSize, onContinue: advance)
                    case .notifications: NotificationsStep(state: state, onContinue: advance)
                    case .goalSetup: GoalSetupStep(onContinue: advance)
                    case .topics: TopicsStep(selection: $state.topics, onContinue: advance)
                    case .exampleCard: ExampleCardStep(targetLanguage: state.targetLanguage, nativeLanguage: state.nativeLanguage, onContinue: advance)
                    case .vocabularyLevel: VocabularyLevelStep(targetLanguage: state.targetLanguage, selection: $state.cefrLevel, onContinue: advance)
                    case .testIntro: TestIntroStep(onContinue: advance)
                    case .beginnerWords: WordPickStep(level: .beginner, selected: $state.knownWordIDs, onContinue: advance)
                    case .intermediateWords: WordPickStep(level: .intermediate, selected: $state.knownWordIDs, onContinue: advance)
                    case .advancedWords: WordPickStep(level: .advanced, selected: $state.knownWordIDs, onContinue: advance)
                    case .finalPitch: FinalPitchStep(
                        targetLanguage: state.targetLanguage ?? .spanish,
                        level: state.cefrLevel ?? .a1,
                        dailySetSize: state.dailySetSize,
                        onContinue: finish
                    )
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: isGoingBack ? .leading : .trailing).combined(with: .opacity),
                    removal: .move(edge: isGoingBack ? .trailing : .leading).combined(with: .opacity)
                ))
            }
        }
        .overlay(alignment: .topLeading) {
            if step != .welcome {
                backButton
            }
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .tint(DS.Color.ink)
    }

    /// Reseed the SwiftData store for the picked language so later steps
    /// (vocabulary level, word-pick steps) see the right vocabulary. No-op
    /// when the picked language already matches what's loaded.
    private func syncSeededLanguage(to newValue: TargetLanguage?) {
        guard let language = newValue else { return }
        let seeded = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.seededLanguage)
        guard seeded != language.rawValue else { return }
        SeedDataLoader.switchLanguage(to: language, context: context)
    }

    private var background: some View {
        DS.Color.paper.ignoresSafeArea()
    }

    private var progressBar: some View {
        let total = OnboardingStep.allCases.count - 1
        let current = max(0, step.rawValue)
        let progress = Double(current) / Double(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(DS.Color.ink)
                    .frame(width: max(8, geo.size.width * progress))
            }
        }
        .frame(height: 6)
    }

    /// Sits level with the progress bar; on the full-bleed panel screens it
    /// floats over the panel instead.
    private var backButton: some View {
        Button(action: goBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .padding(.top, -3)
        .accessibilityLabel("Back")
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        playHaptic()
        isGoingBack = false
        let leaving = step
        step = next
        if leaving == .language {
            // Swapping the vocabulary is a ~1s main-thread job, so it runs
            // once on leaving the picker — not on every row tap — and only
            // after the slide to the next screen has finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                syncSeededLanguage(to: state.targetLanguage)
            }
        }
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        playHaptic()
        // Flip the slide direction first and change step on the next pass,
        // so the outgoing screen has picked up the reversed transition.
        isGoingBack = true
        DispatchQueue.main.async { step = previous }
    }

    private func finish() {
        OnboardingStore.persist(state)
        markKnownWords()
        if state.notificationsAuthorized {
            NotificationService.scheduleReminders(
                using: NotificationService.reminderStack(fallback: DailyWordSnapshot.load()),
                perDay: state.notificationsPerDay,
                start: state.notificationStart,
                end: state.notificationEnd,
                daysOfWeek: OnboardingStore.notificationDaysOfWeek
            )
        }
        DailyWordService.refresh(context: context)
        dismiss()
    }

    private func markKnownWords() {
        guard !state.knownWordIDs.isEmpty else { return }
        let ids = state.knownWordIDs
        let descriptor = FetchDescriptor<VocabularyWord>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        guard let words = try? context.fetch(descriptor), !words.isEmpty else { return }

        let progressDescriptor = FetchDescriptor<LearningProgress>()
        let existing = (try? context.fetch(progressDescriptor)) ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.wordID, $0) })

        for word in words {
            let progress = existingByID[word.id] ?? LearningProgress(wordID: word.id)
            if existingByID[word.id] == nil { context.insert(progress) }
            let result = SRSScheduler.next(progress: progress, rating: .good)
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
                rating: .good,
                intervalBeforeDays: 0,
                intervalAfterDays: result.intervalDays
            )
            context.insert(log)
        }
        try? context.save()
    }

    private func playHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

// MARK: - Shared building blocks

private struct OnboardingScaffold<Content: View>: View {
    /// How a step introduces itself: `spoken` is Dr Tusk saying one line in a
    /// bubble (the default across the flow), `titled` is the plain
    /// title-plus-subtitle block still used by the language picker.
    enum Header {
        case titled(title: LocalizedStringResource, subtitle: LocalizedStringResource?)
        case spoken(LocalizedStringResource)
    }

    let header: Header
    let primaryTitle: LocalizedStringResource
    let primaryEnabled: Bool
    let onPrimary: () -> Void
    @ViewBuilder var content: () -> Content

    init(
        line: LocalizedStringResource,
        primaryTitle: LocalizedStringResource = "Continue",
        primaryEnabled: Bool = true,
        onPrimary: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = .spoken(line)
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.onPrimary = onPrimary
        self.content = content
    }

    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        primaryTitle: LocalizedStringResource = "Continue",
        primaryEnabled: Bool = true,
        onPrimary: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = .titled(title: title, subtitle: subtitle)
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.onPrimary = onPrimary
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerView
                    content()
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }

            primaryButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var headerView: some View {
        switch header {
        case let .titled(title, subtitle):
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.onboardingTitle)
                    .foregroundStyle(Color.whiteboardInk)
                    .padding(.top, 12)
                if let subtitle {
                    Text(subtitle)
                        .font(.sniglet(.title3))
                        .foregroundStyle(DS.Color.charcoal)
                }
            }
            .padding(.horizontal, 24)
        case let .spoken(line):
            WalrusSpeechRow(text: line)
                .padding(.top, 8)
        }
    }

    private var primaryButton: some View {
        Button(primaryTitle, action: onPrimary)
            .buttonStyle(.primary)
            .disabled(!primaryEnabled)
    }
}

private extension View {
    /// Every surface in onboarding — rows, chips, steppers, fields — is a
    /// raised white card, or ink-filled when it's the chosen one. No grey
    /// boxes anywhere in the flow.
    func onboardingCard(isSelected: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? DS.Color.ink : Color.white)
                .shadow(
                    color: DS.Color.ink.opacity(isSelected ? 0.22 : 0.10),
                    radius: 8,
                    y: 3
                )
        )
    }
}

private struct SelectableRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    /// Put the subtitle on the same line as the title. Used by the CEFR
    /// levels, where the code is short enough that stacking wastes a line.
    let inlineSubtitle: Bool

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        inlineSubtitle: Bool = false,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.inlineSubtitle = inlineSubtitle
        self.isSelected = isSelected
        self.action = action
    }

    private var titleText: some View {
        Text(title)
            .font(.sniglet(.headline))
            .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
    }

    @ViewBuilder private var subtitleText: some View {
        if let subtitle {
            // Inline subtitles carry the whole meaning of the row (the level
            // code alone says little), so they read at full size in ink
            // rather than as small grey supporting text.
            Text(subtitle)
                .font(.sniglet(inlineSubtitle ? .subheadline : .caption))
                .foregroundStyle(
                    isSelected
                        ? Color.white.opacity(0.9)
                        : (inlineSubtitle ? DS.Color.ink : Color.secondary)
                )
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.sniglet(.title3))
                        .frame(width: 32)
                        .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
                }
                if inlineSubtitle {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        titleText
                        subtitleText
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        titleText
                        subtitleText
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .onboardingCard(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let onContinue: () -> Void

    /// Runs before the "I speak" picker, so go by the likely native
    /// language: everyone but English speakers learns English. (if/else, not
    /// a ternary — literals in a ternary aren't extracted to the catalog.)
    private var pitch: LocalizedStringResource {
        if NativeLanguage.onboardingDefault == .english {
            return "Learn the most used words in Spanish, French, Italian and German"
        } else {
            return "Learn the most used words in English"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingVideoPanel(dataAssetName: "scenePhoneCheck") {
                Spacer(minLength: 16)
                StickerLogo()
                    .frame(maxWidth: 200)
                Spacer(minLength: 16)
            }
            OnboardingBottomSheet {
                OnboardingHeadline(
                    title: "The effortless way to learn languages",
                    subtitle: pitch
                )
                Button("Continue", action: onContinue)
                    .buttonStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
    }
}

/// How far the bottom sheet rises over the video panel — its corner radius,
/// so the rounded corners sit over the panel's tint rather than a gap.
private let onboardingSheetRadius: CGFloat = 32

/// The paper-coloured lower half of the video screens, drawn as a sheet with
/// rounded top corners lifted over the panel so the walrus disappears behind
/// a soft edge instead of a hard horizontal cut.
private struct OnboardingBottomSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: onboardingSheetRadius,
                topTrailingRadius: onboardingSheetRadius,
                style: .continuous
            )
            .fill(DS.Color.paper)
            .shadow(color: Color.black.opacity(0.08), radius: 10, y: -2)
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Shaded top panel with a looping Dr Tusk clip sat on its bottom edge. The
/// clips are cropped mid-body, so the crop reads as the panel's edge rather
/// than the walrus being cut off. `top` fills the space above his head.
private struct OnboardingVideoPanel<Top: View>: View {
    let dataAssetName: String
    var videoWidth: CGFloat = 280
    /// Points trimmed off the bottom of the clip, so the panel edge cuts
    /// Dr Tusk off higher up his body.
    var bottomCrop: CGFloat = 0
    var pauseBetweenLoops: TimeInterval = 2
    @ViewBuilder let top: Top

    var body: some View {
        VStack(spacing: 0) {
            top
            LoopingVideoView(dataAssetName: dataAssetName, pauseBetweenLoops: pauseBetweenLoops)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: videoWidth)
                .padding(.bottom, -bottomCrop)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.paperShade.ignoresSafeArea(edges: .top))
        // Tuck the bottom under the rounded sheet that follows, so the
        // sheet's corners show the panel's tint behind them.
        .padding(.bottom, -onboardingSheetRadius)
    }
}

/// Centred title and optional subline under an `OnboardingVideoPanel`.
private struct OnboardingHeadline: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.onboardingTitle)
                .foregroundStyle(Color.whiteboardInk)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.sniglet(.title3))
                    .foregroundStyle(DS.Color.charcoal)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .padding(.bottom, 64)
    }
}

/// The wordmark with a white sticker border and a soft lift. The border is
/// drawn by stamping a white silhouette of the logo in a ring around it, so
/// it follows whatever artwork is in the `wordrusLogo` asset.
private struct StickerLogo: View {
    var borderWidth: CGFloat = 4

    var body: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { i in
                let angle = Double(i) / 16 * 2 * .pi
                logo
                    .foregroundStyle(.white)
                    .offset(x: borderWidth * cos(angle), y: borderWidth * sin(angle))
            }
            // Tinted rather than using the SVG's own blue so it matches
            // the title ink exactly.
            logo
                .foregroundStyle(Color.whiteboardInk)
        }
        .padding(borderWidth)
        .compositingGroup()
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Wordrus"))
    }

    private var logo: some View {
        Image("wordrusLogo")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
    }
}

/// Tail size shared by the bubble shape and the padding that clears it.
private let speechTailSize: CGFloat = 10

/// Which edge the bubble's tail sits on: `.leading` points sideways at the
/// avatar beside it, `.bottom` points down at the full-size walrus below.
private enum SpeechTailEdge {
    case leading
    case bottom
}

/// Speech bubble outline, drawn as one continuous path so the stroke never
/// shows a seam where the tail meets the body.
private struct SpeechBubbleShape: Shape {
    var tailEdge: SpeechTailEdge = .leading
    var cornerRadius: CGFloat = 18
    var tailLength: CGFloat = speechTailSize
    var tailSpread: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        switch tailEdge {
        case .leading: leadingTailPath(in: rect)
        case .bottom: bottomTailPath(in: rect)
        }
    }

    private func leadingTailPath(in rect: CGRect) -> Path {
        let left = rect.minX + tailLength
        let r = min(cornerRadius, min(rect.width - tailLength, rect.height) / 2)
        let halfTail = min(tailSpread / 2, max(0, rect.height / 2 - r))
        let tipY = rect.midY

        var path = Path()
        path.move(to: CGPoint(x: left + r, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left, y: rect.maxY - r),
            radius: r
        )
        path.addLine(to: CGPoint(x: left, y: tipY + halfTail))
        path.addLine(to: CGPoint(x: rect.minX, y: tipY))
        path.addLine(to: CGPoint(x: left, y: tipY - halfTail))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.minY),
            tangent2End: CGPoint(x: left + r, y: rect.minY),
            radius: r
        )
        path.closeSubpath()
        return path
    }

    private func bottomTailPath(in rect: CGRect) -> Path {
        let bottom = rect.maxY - tailLength
        let r = min(cornerRadius, min(rect.width, bottom - rect.minY) / 2)
        let halfTail = min(tailSpread / 2, max(0, rect.width / 2 - r))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bottom),
            tangent2End: CGPoint(x: rect.maxX - r, y: bottom),
            radius: r
        )
        path.addLine(to: CGPoint(x: rect.midX + halfTail, y: bottom))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - halfTail, y: bottom))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bottom),
            tangent2End: CGPoint(x: rect.minX, y: bottom - r),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + r, y: rect.minY),
            radius: r
        )
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// Flat white bubble — Dr Tusk's onboarding voice. Deliberately plainer
    /// than the chat `walrusBubbleStyle` liquid gradient so the copy reads
    /// first. Padding on the tail's edge leaves room for the tail itself.
    func onboardingSpeechBubble(tailEdge: SpeechTailEdge = .leading) -> some View {
        let shape = SpeechBubbleShape(tailEdge: tailEdge)
        return self
            // Held well short of the screen width so longer lines wrap
            // into a compact block rather than one edge-to-edge run.
            .frame(maxWidth: 220, alignment: .leading)
            .foregroundStyle(DS.Color.ink)
            .padding(.leading, tailEdge == .leading ? 14 + speechTailSize : 14)
            .padding(.trailing, 14)
            .padding(.top, 12)
            .padding(.bottom, tailEdge == .bottom ? 12 + speechTailSize : 12)
            .background(shape.fill(Color.white))
            .overlay(shape.stroke(DS.Color.ink.opacity(0.12), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
    }
}

/// Dr Tusk's head in a circle — his stand-in wherever he speaks in
/// onboarding without taking over the screen.
private struct WalrusAvatar: View {
    var size: CGFloat = 76

    var body: some View {
        // The art is a full-body walrus; zoom in from the top so the circle
        // frames his face rather than the whole animal.
        Image("walrus")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .scaleEffect(1.5, anchor: .top)
            // Drop him a little so there's headroom above his head.
            .offset(y: size * 0.1)
            .frame(width: size, height: size)
            // Same warm shade as the panels behind the full-size clips.
            .background(Circle().fill(DS.Color.paperShade))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 5))
            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
    }
}

/// Avatar plus the line he's saying — the onboarding equivalent of a chat
/// row, shared by every step where Dr Tusk speaks.
private struct WalrusSpeechRow: View {
    let text: LocalizedStringResource

    @State private var bubbleVisible = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            WalrusAvatar()
            Text(text)
                .font(.sniglet(.title3))
                .multilineTextAlignment(.leading)
                .onboardingSpeechBubble()
                // A gentle fade-and-settle in place, rather than sliding
                // out from behind the avatar.
                .opacity(bubbleVisible ? 1 : 0)
                .offset(y: bubbleVisible ? 0 : 4)
        }
        .padding(.horizontal, 24)
        // Breathing room so the row never sits tight against the progress
        // bar above or the first card below.
        .padding(.vertical, 12)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35).delay(0.15)) {
                bubbleVisible = true
            }
        }
    }
}

/// Dr Tusk's own introduction — he waves from the video panel rather than
/// appearing as a chat-style avatar, with the bubble above him.
private struct WalrusIntroStep: View {
    let onContinue: () -> Void

    @State private var bubbleVisible = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingVideoPanel(dataAssetName: "sceneWave", videoWidth: 390, bottomCrop: 70) {
                Spacer(minLength: 56)
                Text("Hi, I'm Dr Tusk. A few quick questions before we begin.")
                    .font(.sniglet(.title3))
                    .multilineTextAlignment(.leading)
                    .onboardingSpeechBubble(tailEdge: .bottom)
                    .opacity(bubbleVisible ? 1 : 0)
                    .offset(y: bubbleVisible ? 0 : 12)
                    .padding(.bottom, 8)
            }
            OnboardingBottomSheet {
                Button("Continue", action: onContinue)
                    .buttonStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                bubbleVisible = true
            }
        }
    }
}

private struct LanguageStep: View {
    @Binding var native: NativeLanguage
    @Binding var selection: TargetLanguage?
    let onContinue: () -> Void

    private var offered: [TargetLanguage] { TargetLanguage.offered(to: native) }

    var body: some View {
        OnboardingScaffold(
            title: "What do you want to learn?",
            subtitle: "You can switch languages later.",
            primaryEnabled: selection.map(offered.contains) ?? false,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                if NativeLanguage.selectable.count > 1 {
                    NativeLanguageMenu(selection: $native)
                        .padding(.bottom, 6)
                }
                ForEach(offered) { language in
                    LanguageRow(
                        language: language,
                        isSelected: selection == language
                    ) {
                        selection = language
                    }
                }
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: native) { reconcileSelection() }
    }

    /// Drop a target the new native language can't learn, and pre-pick the
    /// only option when there is just one (every non-English speaker).
    private func reconcileSelection() {
        if let current = selection, !offered.contains(current) {
            selection = nil
        }
        if selection == nil, offered.count == 1 {
            selection = offered.first
        }
    }
}

/// "I speak …" selector shown above the target list once more than one
/// native language has something to learn.
private struct NativeLanguageMenu: View {
    @Binding var selection: NativeLanguage

    var body: some View {
        Menu {
            Picker("I speak", selection: $selection) {
                ForEach(NativeLanguage.selectable) { language in
                    Text(verbatim: language.endonym).tag(language)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("I speak")
                    .foregroundStyle(.secondary)
                Text(verbatim: selection.endonym)
                    .foregroundStyle(DS.Color.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            .font(.sniglet(.headline))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LanguageRow: View {
    let language: TargetLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(language.flagAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.title)
                        .font(.sniglet(.headline))
                        .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
                    Text(language.subtitle)
                        .font(.sniglet(.caption))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .onboardingCard(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct NameStep: View {
    @Binding var name: String
    let onContinue: () -> Void
    @FocusState private var isFocused: Bool

    var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            WalrusSpeechRow(text: "How should I call you?")

            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($isFocused)
                .padding(16)
                .onboardingCard()
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .onSubmit {
                    if !trimmed.isEmpty { onContinue() }
                }

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .disabled(trimmed.isEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }
}

private struct CustomizeIntroStep: View {
    let name: String
    let onContinue: () -> Void

    private var greeting: LocalizedStringResource {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Let's set your learning pace."
            : "OK \(trimmed), let's set your learning pace."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            WalrusSpeechRow(text: greeting)

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

private struct DailyGoalStep: View {
    @Binding var size: Int
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            line: "How many new words shall we do each day?",
            onPrimary: onContinue
        ) {
            HStack(spacing: 16) {
                Text(AttributedString(
                    localized: "\(size) words",
                    emphasizingCount: size,
                    font: .gochiHand(size: 64, relativeTo: .largeTitle),
                    color: .whiteboardInk
                ))
                .font(.sniglet(.title3))
                .foregroundStyle(DS.Color.charcoal)
                .monospacedDigit()
                Spacer()
                HStack(spacing: 14) {
                    stepButton("minus", enabled: size > DailySetConfig.minSize) {
                        size = max(DailySetConfig.minSize, size - 1)
                    }
                    stepButton("plus", enabled: size < DailySetConfig.maxSize) {
                        size = min(DailySetConfig.maxSize, size + 1)
                    }
                }
            }
            .padding(16)
            .onboardingCard()
        }
    }

    private func stepButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.sniglet(.title2, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.Color.ink))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct NotificationsStep: View {
    @Bindable var state: OnboardingState
    let onContinue: () -> Void

    @State private var startDate: Date = Self.date(from: DateComponents(hour: 9, minute: 0))
    @State private var endDate: Date = Self.date(from: DateComponents(hour: 20, minute: 0))
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WalrusSpeechRow(text: "When shall I send you words through the day?")

                    VStack(spacing: 12) {
                        DatePicker(
                            "Start",
                            selection: $startDate,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: startDate) { _, newValue in
                            state.notificationStart = Self.components(from: newValue)
                        }
                        DatePicker(
                            "End",
                            selection: $endDate,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: endDate) { _, newValue in
                            state.notificationEnd = Self.components(from: newValue)
                        }
                    }
                    .padding(16)
                    .onboardingCard()
                    // The speech row brings its own horizontal inset, so the
                    // card is padded on its own rather than with the stack.
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            VStack(spacing: 10) {
                Button {
                    Task { await requestAndContinue() }
                } label: {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Allow and save")
                    }
                }
                .buttonStyle(.primary)
                .disabled(isRequesting)

                Button("Not now") {
                    state.notificationsAuthorized = false
                    onContinue()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isRequesting)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .onAppear {
            state.notificationStart = Self.components(from: startDate)
            state.notificationEnd = Self.components(from: endDate)
        }
    }

    private func requestAndContinue() async {
        isRequesting = true
        let granted = await NotificationService.requestAuthorization()
        isRequesting = false
        state.notificationsAuthorized = granted
        onContinue()
    }

    private static func date(from components: DateComponents) -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: components.hour ?? 9, minute: components.minute ?? 0, second: 0, of: .now) ?? .now
    }

    private static func components(from date: Date) -> DateComponents {
        Calendar.current.dateComponents([.hour, .minute], from: date)
    }
}

// MARK: - Goal setup intro

private struct GoalSetupStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            WalrusSpeechRow(text: "Now tell me what matters to you, and I'll teach those words first.")

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Topics

private struct TopicsStep: View {
    @Binding var selection: Set<LearningTopic>
    let onContinue: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        OnboardingScaffold(
            line: "Pick the topics that matter to you — as many as you like.",
            primaryEnabled: !selection.isEmpty,
            onPrimary: onContinue
        ) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LearningTopic.allCases) { topic in
                    TopicChip(topic: topic, isSelected: selection.contains(topic)) {
                        if selection.contains(topic) {
                            selection.remove(topic)
                        } else {
                            selection.insert(topic)
                        }
                    }
                }
            }
        }
    }
}

private struct TopicChip: View {
    let topic: LearningTopic
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: topic.systemImage)
                    .font(.sniglet(.title2))
                    .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
                Text(topic.title)
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(12)
            .onboardingCard(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Example card preview

private struct ExampleCardStep: View {
    let targetLanguage: TargetLanguage?
    let nativeLanguage: NativeLanguage
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WalrusSpeechRow(text: "Every word comes with an example you can hear out loud.")
                        .padding(.top, 12)

                    ExamplePreviewCard(language: targetLanguage ?? .spanish, native: nativeLanguage)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
}

/// A short, hand-picked demo word per language for the onboarding preview so
/// the card the learner first sees is in the language they just chose rather
/// than always Spanish. The definition and translation are in the learner's
/// native language — English for the four European targets, which are only
/// offered to English speakers.
private struct OnboardingExample {
    let word: String
    let partOfSpeech: String
    let definition: String
    let sentence: String
    let translation: String

    static func forLanguage(_ language: TargetLanguage, native: NativeLanguage) -> OnboardingExample {
        switch language {
        case .spanish:
            OnboardingExample(
                word: "conocer",
                partOfSpeech: "verb",
                definition: "to know (a person or place)",
                sentence: "Quiero conocer Madrid algún día.",
                translation: "I want to visit Madrid one day."
            )
        case .french:
            OnboardingExample(
                word: "connaître",
                partOfSpeech: "verb",
                definition: "to know (a person or place)",
                sentence: "Je veux connaître Paris un jour.",
                translation: "I want to get to know Paris one day."
            )
        case .italian:
            OnboardingExample(
                word: "conoscere",
                partOfSpeech: "verb",
                definition: "to know (a person or place)",
                sentence: "Voglio conoscere Roma un giorno.",
                translation: "I want to get to know Rome one day."
            )
        case .german:
            OnboardingExample(
                word: "kennenlernen",
                partOfSpeech: "verb",
                definition: "to get to know (a person or place)",
                sentence: "Ich möchte Berlin eines Tages kennenlernen.",
                translation: "I want to get to know Berlin one day."
            )
        case .english:
            OnboardingExample(
                word: "meet",
                partOfSpeech: "verb",
                definition: englishMeetDefinition[native] ?? "to see someone for the first time",
                sentence: "I'd love to meet your family one day.",
                translation: englishMeetTranslation[native] ?? "I'd love to meet your family one day."
            )
        }
    }

    private static let englishMeetDefinition: [NativeLanguage: String] = [
        .spanish: "conocer (a alguien)",
        .french: "rencontrer (quelqu'un)",
        .italian: "conoscere (qualcuno)",
        .german: "kennenlernen (jemanden)",
    ]

    private static let englishMeetTranslation: [NativeLanguage: String] = [
        .spanish: "Me encantaría conocer a tu familia algún día.",
        .french: "J'aimerais beaucoup rencontrer ta famille un jour.",
        .italian: "Mi piacerebbe conoscere la tua famiglia un giorno.",
        .german: "Ich würde gern eines Tages deine Familie kennenlernen.",
    ]
}

private struct ExamplePreviewCard: View {
    let language: TargetLanguage
    let native: NativeLanguage

    private var example: OnboardingExample { .forLanguage(language, native: native) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(example.word)
                        .font(.gochiHand(size: 48))
                        .foregroundStyle(Color.whiteboardInk)
                    Text(PartOfSpeechLabel.localized(example.partOfSpeech))
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    Text(example.definition)
                        .font(.sniglet(.title3))
                        .padding(.top, 2)
                }
                Spacer()
                Button {
                    SpeechService.shared.speak(example.sentence, languageCode: language.bcp47)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.sniglet(.title3))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(DS.Color.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hear it spoken aloud")
            }

            InkDivider()

            VStack(alignment: .leading, spacing: 4) {
                Text(example.sentence)
                    .font(.sniglet(.title3))
                    .italic()
                Text(example.translation)
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            }

            Label("Tap to hear it spoken aloud", systemImage: "ear.fill")
                .font(.sniglet(.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            SpeechService.shared.speak(example.sentence, languageCode: language.bcp47)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
        )
    }
}

// MARK: - Vocabulary level

private struct VocabularyLevelStep: View {
    let targetLanguage: TargetLanguage?
    @Binding var selection: CEFRLevel?
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            line: "Where are you with \((targetLanguage ?? .spanish).title) — A1 is brand new, C2 is near-native.",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(CEFRLevel.allCases) { level in
                    // No icon here — the level code is the badge, and the
                    // leaf/flame/bolt set read as arbitrary next to it.
                    SelectableRow(
                        title: level.title,
                        subtitle: level.subtitle,
                        inlineSubtitle: true,
                        isSelected: selection == level
                    ) {
                        selection = level
                    }
                }
            }
        }
    }
}

// MARK: - Knowledge test intro

private struct TestIntroStep: View {
    let onContinue: () -> Void

    @State private var bubbleVisible = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingVideoPanel(dataAssetName: "sceneTest", videoWidth: 390, bottomCrop: 70) {
                Spacer(minLength: 56)
                Text("Now let's see how many words you already know.")
                    .font(.sniglet(.title3))
                    .multilineTextAlignment(.leading)
                    .onboardingSpeechBubble(tailEdge: .bottom)
                    .opacity(bubbleVisible ? 1 : 0)
                    .offset(y: bubbleVisible ? 0 : 12)
                    .padding(.bottom, 8)
            }
            OnboardingBottomSheet {
                Button("Continue", action: onContinue)
                    .buttonStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                bubbleVisible = true
            }
        }
    }
}

// MARK: - Word selection

private struct WordPickStep: View {
    let level: VocabularyLevel
    @Binding var selected: Set<String>
    let onContinue: () -> Void

    @Environment(\.modelContext) private var context

    /// The six words on screen. Built once when the step appears — deriving
    /// it means filtering and sorting the whole catalogue, which made every
    /// chip tap stall while the body recomputed it several times over.
    @State private var sample: [VocabularyWord] = []

    private static let maxPicks = sampleSize

    private static let sampleSize = 6
    nonisolated private static let contentPOSPrefixes = ["noun", "verb", "adjective", "adverb"]
    nonisolated private static let posOrder = ["verb", "noun", "adjective", "adverb"]

    /// Pick a sample with POS variety — round-robin across verb/noun/
    /// adjective/adverb buckets so the user doesn't see six of the same kind.
    /// Words in this level's rank band come first; if the band is too thin to
    /// fill the sample (some languages' datasets are sparse), we backfill from
    /// the nearest ranks outside the band so the screen is never empty.
    private static func makeSample(level: VocabularyLevel, context: ModelContext) -> [VocabularyWord] {
        let range = level.rankRange
        let all = (try? context.fetch(FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.rank)]))) ?? []
        // Read each persisted property once up front; SwiftData property
        // access is slow enough to matter inside a sort comparator.
        let candidates = all
            .map { (word: $0, rank: $0.rank, pos: primaryPOS(of: $0.partOfSpeech)) }
            .filter { isContentful($0.word) }
            .sorted { lhs, rhs in
                let lIn = range.contains(lhs.rank)
                let rIn = range.contains(rhs.rank)
                if lIn != rIn { return lIn }                 // in-band first
                if lIn { return lhs.rank < rhs.rank }         // within band, by rank
                return distance(lhs.rank, to: range)          // outside band, nearest first
                    < distance(rhs.rank, to: range)
            }
        let buckets = posOrder.map { category in
            candidates.filter { $0.pos == category }.map(\.word)
        }
        var picks: [VocabularyWord] = []
        var index = 0
        while picks.count < sampleSize {
            var addedThisRound = false
            for bucket in buckets {
                guard index < bucket.count else { continue }
                picks.append(bucket[index])
                addedThisRound = true
                if picks.count >= sampleSize { break }
            }
            if !addedThisRound { break }
            index += 1
        }
        return picks
    }

    nonisolated private static func isContentful(_ word: VocabularyWord) -> Bool {
        guard word.lemma.count >= 4 else { return false }
        let pos = word.partOfSpeech.lowercased()
        return contentPOSPrefixes.contains { pos.hasPrefix($0) }
    }

    /// How far `rank` sits outside `range` (0 when inside). Used to order the
    /// backfill so words just past the band are preferred over distant ones.
    nonisolated private static func distance(_ rank: Int, to range: ClosedRange<Int>) -> Int {
        if rank < range.lowerBound { return range.lowerBound - rank }
        if rank > range.upperBound { return rank - range.upperBound }
        return 0
    }

    nonisolated private static func primaryPOS(of partOfSpeech: String) -> String {
        let p = partOfSpeech.lowercased()
        if p.contains("verb"), !p.contains("adverb") { return "verb" }
        if p.contains("noun") { return "noun" }
        if p.contains("adjective") { return "adjective" }
        if p.contains("adverb") { return "adverb" }
        return "other"
    }

    private var pickedAtThisLevel: Int {
        sample.reduce(0) { $0 + (selected.contains($1.id) ? 1 : 0) }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        let picked = pickedAtThisLevel
        OnboardingScaffold(
            line: line,
            primaryTitle: picked == 0 ? "Skip" : "Continue",
            onPrimary: onContinue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(picked) / \(Self.maxPicks) selected")
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(sample) { word in
                        WordPickChip(
                            word: word,
                            isSelected: selected.contains(word.id),
                            isDisabled: !selected.contains(word.id) && picked >= Self.maxPicks
                        ) {
                            toggle(word)
                        }
                    }
                }
            }
        }
        .onAppear {
            if sample.isEmpty { sample = Self.makeSample(level: level, context: context) }
        }
    }

    private var line: LocalizedStringResource {
        switch level {
        case .beginner: "Tap any of these you already know — up to 6."
        case .intermediate: "How about these?"
        case .advanced: "And these tricky ones?"
        }
    }

    private func toggle(_ word: VocabularyWord) {
        if selected.contains(word.id) {
            selected.remove(word.id)
        } else if pickedAtThisLevel < Self.maxPicks {
            selected.insert(word.id)
        }
    }
}

/// Squashes on press and springs back past its resting size, so tapping a
/// word feels like it answers back.
private struct BounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(
                .spring(response: 0.3, dampingFraction: 0.45),
                value: configuration.isPressed
            )
    }
}

private struct WordPickChip: View {
    let word: VocabularyWord
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(word.lemma.capitalizedFirst)
                    .font(.gochiHand(size: 28, relativeTo: .title3))
                    .foregroundStyle(isSelected ? Color.white : Color.whiteboardInk)
                Text(PartOfSpeechLabel.localized(word.partOfSpeech))
                    .font(.sniglet(.caption2))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 10)
            .onboardingCard(isSelected: isSelected)
            .opacity(isDisabled ? 0.45 : 1.0)
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(isDisabled)
    }
}

// MARK: - Final pitch

private struct FinalPitchStep: View {
    let targetLanguage: TargetLanguage
    let level: CEFRLevel
    let dailySetSize: Int
    let onContinue: () -> Void

    @State private var bubbleVisible = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingVideoPanel(dataAssetName: "sceneCoffee", videoWidth: 390, bottomCrop: 70) {
                Spacer(minLength: 16)
                Text("Give me a minute a day and I'll do the rest.")
                    .font(.sniglet(.title3))
                    .multilineTextAlignment(.leading)
                    .onboardingSpeechBubble(tailEdge: .bottom)
                    .opacity(bubbleVisible ? 1 : 0)
                    .offset(y: bubbleVisible ? 0 : 12)
                    .padding(.bottom, 8)
            }
            OnboardingBottomSheet {
                OnboardingHeadline(
                    title: "You're all set",
                    subtitle: "Let's start learning \(targetLanguage.title) at \(level.title),\n\(dailySetSize) new words a day."
                )
                Button("Start learning", action: onContinue)
                    .buttonStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                bubbleVisible = true
            }
        }
    }
}

#Preview {
    OnboardingFlow()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
