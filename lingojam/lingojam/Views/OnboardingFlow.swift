import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case walrusIntro
    case language
    case referral
    case tailorIntro
    case age
    case name
    case customizeIntro
    case weeklyGoal
    case notifications
    case goalSetup
    case topics
    case learningReason
    case exampleCard
    case vocabularyLevel
    case testIntro
    case beginnerWords
    case intermediateWords
    case advancedWords
    case personalizationConfirm
    case finalPitch
}

struct OnboardingFlow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var state = OnboardingState()
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                if step != .welcome && step != .walrusIntro {
                    progressBar
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }

                Group {
                    switch step {
                    case .welcome: WelcomeStep(onContinue: advance)
                    case .walrusIntro: WalrusIntroStep(onContinue: advance)
                    case .language: LanguageStep(selection: $state.targetLanguage, onContinue: advance)
                    case .referral: ReferralStep(selection: $state.referralSource, onContinue: advance)
                    case .tailorIntro: TailorIntroStep(onContinue: advance)
                    case .age: AgeStep(selection: $state.ageBand, onContinue: advance)
                    case .name: NameStep(name: $state.displayName, onContinue: advance)
                    case .customizeIntro: CustomizeIntroStep(onContinue: advance)
                    case .weeklyGoal: WeeklyGoalStep(selection: $state.weeklyGoal, onContinue: advance)
                    case .notifications: NotificationsStep(state: state, onContinue: advance)
                    case .goalSetup: GoalSetupStep(onContinue: advance)
                    case .topics: TopicsStep(selection: $state.topics, onContinue: advance)
                    case .learningReason: LearningReasonStep(targetLanguage: state.targetLanguage, selection: $state.learningReason, onContinue: advance)
                    case .exampleCard: ExampleCardStep(onContinue: advance)
                    case .vocabularyLevel: VocabularyLevelStep(targetLanguage: state.targetLanguage, selection: $state.cefrLevel, onContinue: advance)
                    case .testIntro: TestIntroStep(onContinue: advance)
                    case .beginnerWords: WordPickStep(level: .beginner, selected: $state.knownWordIDs, onContinue: advance)
                    case .intermediateWords: WordPickStep(level: .intermediate, selected: $state.knownWordIDs, onContinue: advance)
                    case .advancedWords: WordPickStep(level: .advanced, selected: $state.knownWordIDs, onContinue: advance)
                    case .personalizationConfirm: PersonalizationConfirmStep(onContinue: advance)
                    case .finalPitch: FinalPitchStep(onContinue: finish)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .tint(DS.Color.ink)
        .onChange(of: state.targetLanguage) { _, newValue in
            syncSeededLanguage(to: newValue)
        }
    }

    /// Reseed the SwiftData store the moment the user picks a language so
    /// subsequent onboarding steps (vocabulary level, word-pick steps) see
    /// the right vocabulary. No-op when the picked language already matches
    /// what's loaded.
    private func syncSeededLanguage(to newValue: TargetLanguage?) {
        guard let language = newValue else { return }
        let seeded = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.seededLanguage)
        guard seeded != language.rawValue else { return }
        SeedDataLoader.switchLanguage(to: language, context: context)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(.systemBackground), DS.Color.ink.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
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

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        playHaptic()
        step = next
    }

    private func finish() {
        OnboardingStore.persist(state)
        markKnownWords()
        if state.notificationsAuthorized,
           let snapshot = DailyWordSnapshot.load() {
            NotificationService.scheduleReminders(
                using: snapshot,
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
    let title: String
    let subtitle: String?
    let primaryTitle: String
    let primaryEnabled: Bool
    let onPrimary: () -> Void
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        primaryTitle: String = "Continue",
        primaryEnabled: Bool = true,
        onPrimary: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.onPrimary = onPrimary
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.gochiHand(size: 44, relativeTo: .largeTitle))
                        .foregroundStyle(Color.whiteboardInk)
                        .padding(.top, 12)
                    if let subtitle {
                        Text(subtitle)
                            .font(.sniglet(.title3))
                            .foregroundStyle(.secondary)
                    }
                    content()
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            primaryButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }

    private var primaryButton: some View {
        Button(primaryTitle, action: onPrimary)
            .buttonStyle(.primary)
            .disabled(!primaryEnabled)
    }
}

private struct SelectableRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.sniglet(.headline))
                        .foregroundStyle(isSelected ? Color.white : .primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.sniglet(.caption))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
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
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Color.ink : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 160)
            VStack(spacing: 16) {
                Text("Expand your vocabulary in 1 minute a day")
                    .font(.gochiHand(size: 44, relativeTo: .largeTitle))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Learn 10,000+ new words with a new daily habit that just takes one minute.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Get started", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

private struct WalrusIntroStep: View {
    let onContinue: () -> Void

    @State private var bubbleVisible = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            SpeechBubble {
                Text("Hi, I'm Walter — a few questions before I teach you how to speak…")
                    .font(.sniglet(.title3))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.leading)
            }
            .opacity(bubbleVisible ? 1 : 0)
            .offset(y: bubbleVisible ? 0 : 12)
            .padding(.horizontal, 24)

            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 160)
                .padding(.top, 4)

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                bubbleVisible = true
            }
        }
    }
}

/// Rounded speech bubble with a little tail pointing down-left toward the
/// walrus speaker.
private struct SpeechBubble<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SpeechBubbleShape()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            )
            .overlay(
                SpeechBubbleShape()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 22
    var tailWidth: CGFloat = 22
    var tailHeight: CGFloat = 14
    /// 0 = far left of the bottom edge, 1 = far right.
    var tailPosition: CGFloat = 0.22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)

        path.addRoundedRect(in: body, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        let anchorX = body.minX + (body.width * tailPosition)
        let tailStart = CGPoint(x: anchorX, y: body.maxY)
        let tailTip = CGPoint(x: anchorX + tailWidth * 0.2, y: rect.maxY)
        let tailEnd = CGPoint(x: anchorX + tailWidth, y: body.maxY)

        var tail = Path()
        tail.move(to: tailStart)
        tail.addLine(to: tailTip)
        tail.addLine(to: tailEnd)
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}

private struct LanguageStep: View {
    @Binding var selection: TargetLanguage?
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Which language do you want to learn?",
            subtitle: "Pick one to get started — you can add more later.",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(TargetLanguage.allCases) { language in
                    LanguageRow(
                        language: language,
                        isSelected: selection == language
                    ) {
                        selection = language
                    }
                }
            }
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
                Text(language.flag)
                    .font(.sniglet(size: 32))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.title)
                        .font(.sniglet(.headline))
                        .foregroundStyle(isSelected ? Color.white : .primary)
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
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Color.ink : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ReferralStep: View {
    @Binding var selection: ReferralSource?
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "How did you hear about Lingojam?",
            subtitle: "Pick the option that fits best.",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(ReferralSource.allCases) { source in
                    SelectableRow(
                        title: source.title,
                        systemImage: source.systemImage,
                        isSelected: selection == source
                    ) {
                        selection = source
                    }
                }
            }
        }
    }
}

private struct TailorIntroStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.sniglet(size: 64, weight: .light))
                .foregroundStyle(DS.Color.ink)
            VStack(spacing: 12) {
                Text("Tailor your word recommendations")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("A few quick questions help us pick words that fit you.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

private struct AgeStep: View {
    @Binding var selection: AgeBand?
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "How old are you?",
            subtitle: "We use this to pick examples that suit you.",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(AgeBand.allCases) { band in
                    SelectableRow(
                        title: band.title,
                        isSelected: selection == band
                    ) {
                        selection = band
                    }
                }
            }
        }
    }
}

private struct NameStep: View {
    @Binding var name: String
    let onContinue: () -> Void
    @FocusState private var isFocused: Bool

    var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        OnboardingScaffold(
            title: "What do you want to be called?",
            subtitle: "We'll use this around the app.",
            primaryEnabled: !trimmed.isEmpty,
            onPrimary: onContinue
        ) {
            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($isFocused)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .onSubmit {
                    if !trimmed.isEmpty { onContinue() }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        isFocused = true
                    }
                }
        }
    }
}

private struct CustomizeIntroStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.sniglet(size: 64, weight: .light))
                .foregroundStyle(DS.Color.ink)
            VStack(spacing: 12) {
                Text("Customize the app to improve your experience")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Set a learning pace and daily reminders.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

private struct WeeklyGoalStep: View {
    @Binding var selection: WeeklyGoal
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "How many words do you want to learn per week?",
            subtitle: "You can change this any time.",
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(WeeklyGoal.allCases) { goal in
                    SelectableRow(
                        title: goal.title,
                        subtitle: goal.subtitle,
                        isSelected: selection == goal
                    ) {
                        selection = goal
                    }
                }
            }
        }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Get words throughout the day")
                            .font(.gochiHand(size: 40, relativeTo: .title))
                            .foregroundStyle(Color.whiteboardInk)
                        Text("Allow notifications to get daily words. You can tweak how many and when.")
                            .font(.sniglet(.title3))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Words per day")
                                .font(.sniglet(.headline))
                            Spacer()
                            Text("\(state.notificationsPerDay)")
                                .font(.sniglet(.title3, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(DS.Color.ink)
                        }
                        Stepper(
                            "Words per day",
                            value: $state.notificationsPerDay,
                            in: 1...24
                        )
                        .labelsHidden()
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )

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
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
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
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "target")
                .font(.sniglet(size: 64, weight: .light))
                .foregroundStyle(DS.Color.ink)
            VStack(spacing: 12) {
                Text("Set up vocabulary to help you achieve your goals")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Pick what matters to you and we'll prioritize it.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
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
            title: "Which topics are you interested in?",
            subtitle: "Pick as many as you like.",
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
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? DS.Color.ink : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Learning reason

private struct LearningReasonStep: View {
    let targetLanguage: TargetLanguage?
    @Binding var selection: LearningReason?
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Why do you want to learn \((targetLanguage ?? .spanish).englishName)?",
            subtitle: "We'll surface examples that match.",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(LearningReason.allCases) { reason in
                    SelectableRow(
                        title: reason.title,
                        subtitle: reason.subtitle,
                        systemImage: reason.systemImage,
                        isSelected: selection == reason
                    ) {
                        selection = reason
                    }
                }
            }
        }
    }
}

// MARK: - Example card preview

private struct ExampleCardStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Get deeper insight into each word you learn")
                        .font(.gochiHand(size: 40, relativeTo: .title))
                        .foregroundStyle(Color.whiteboardInk)
                        .padding(.top, 12)

                    ExamplePreviewCard()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
}

private struct ExamplePreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("conocer")
                        .font(.gochiHand(size: 48))
                        .foregroundStyle(Color.whiteboardInk)
                    Text("verb")
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    Text("to know (a person or place)")
                        .font(.sniglet(.title3))
                        .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "speaker.wave.2.fill")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.gray.opacity(0.15), in: Circle())
            }

            InkDivider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Quiero conocer Madrid algún día.")
                    .font(.sniglet(.title3))
                    .italic()
                Text("I want to visit Madrid one day.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            }

            Label("Tap to hear it spoken aloud", systemImage: "ear.fill")
                .font(.sniglet(.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            title: "What's your \((targetLanguage ?? .spanish).englishName) level?",
            subtitle: "We use the CEFR scale (A1 is brand new, C2 is near-native).",
            primaryEnabled: selection != nil,
            onPrimary: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(CEFRLevel.allCases) { level in
                    SelectableRow(
                        title: level.title,
                        subtitle: level.subtitle,
                        systemImage: level.systemImage,
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

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220)
            VStack(spacing: 12) {
                Text("Let's test how many words you know")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Tap the words you already know. Pick up to 6 at each level.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Word selection

private struct WordPickStep: View {
    let level: VocabularyLevel
    @Binding var selected: Set<String>
    let onContinue: () -> Void

    @Query private var allWords: [VocabularyWord]

    private static let maxPicks = sampleSize

    init(level: VocabularyLevel, selected: Binding<Set<String>>, onContinue: @escaping () -> Void) {
        self.level = level
        self._selected = selected
        self.onContinue = onContinue

        let lower = level.rankRange.lowerBound
        let upper = level.rankRange.upperBound
        let predicate = #Predicate<VocabularyWord> { word in
            word.rank >= lower && word.rank <= upper
        }
        _allWords = Query(filter: predicate, sort: \VocabularyWord.rank)
    }

    private static let sampleSize = 6
    nonisolated private static let contentPOSPrefixes = ["noun", "verb", "adjective", "adverb"]
    nonisolated private static let posOrder = ["verb", "noun", "adjective", "adverb"]

    /// Pick a sample with POS variety — round-robin across verb/noun/
    /// adjective/adverb buckets so the user doesn't see six of the same kind.
    /// Within each bucket, words come out in rank order.
    private var sample: [VocabularyWord] {
        let candidates = allWords.filter(Self.isContentful)
        let buckets = Self.posOrder.map { category in
            candidates.filter { Self.primaryPOS(of: $0.partOfSpeech) == category }
        }
        var picks: [VocabularyWord] = []
        var index = 0
        while picks.count < Self.sampleSize {
            var addedThisRound = false
            for bucket in buckets {
                guard index < bucket.count else { continue }
                picks.append(bucket[index])
                addedThisRound = true
                if picks.count >= Self.sampleSize { break }
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

    nonisolated private static func primaryPOS(of partOfSpeech: String) -> String {
        let p = partOfSpeech.lowercased()
        if p.contains("verb"), !p.contains("adverb") { return "verb" }
        if p.contains("noun") { return "noun" }
        if p.contains("adjective") { return "adjective" }
        if p.contains("adverb") { return "adverb" }
        return "other"
    }

    private var pickedAtThisLevel: Int {
        sample.filter { selected.contains($0.id) }.count
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        OnboardingScaffold(
            title: title,
            subtitle: "Tap any you already know — up to 6.",
            primaryTitle: pickedAtThisLevel == 0 ? "Skip" : "Continue",
            onPrimary: onContinue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(pickedAtThisLevel) / \(Self.maxPicks) selected")
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(sample) { word in
                        WordPickChip(
                            word: word,
                            isSelected: selected.contains(word.id),
                            isDisabled: !selected.contains(word.id) && pickedAtThisLevel >= Self.maxPicks
                        ) {
                            toggle(word)
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        switch level {
        case .beginner: "Which of these do you know?"
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
                Text(word.partOfSpeech)
                    .font(.sniglet(.caption2))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Color.ink : Color.secondary.opacity(0.12))
            )
            .opacity(isDisabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Personalization confirm

private struct PersonalizationConfirmStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(DS.Color.ink.opacity(0.18))
                    .frame(width: 140, height: 140)
                Image(systemName: "checkmark")
                    .font(.sniglet(size: 64, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
            }
            VStack(spacing: 12) {
                Text("Great — we personalised the app to your level")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Your daily words and reviews are tailored to you.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Final pitch

private struct FinalPitchStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220)
            VStack(spacing: 14) {
                Text("Become articulate in just 1 minute a day")
                    .font(.gochiHand(size: 40, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                Text("Without even opening the app.")
                    .font(.sniglet(.title3))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button("Start learning", action: onContinue)
                .buttonStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }
}

#Preview {
    OnboardingFlow()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
