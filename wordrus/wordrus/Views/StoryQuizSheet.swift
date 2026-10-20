import SwiftUI
import SwiftData

extension View {
    /// Presents a story: the article first; its "Take quiz" closes the
    /// article and, once it's gone, opens the quiz in its own sheet.
    func storySheet(item story: Binding<DailyStory?>) -> some View {
        modifier(StorySheetPresenter(story: story))
    }
}

private struct StorySheetPresenter: ViewModifier {
    @Binding var story: DailyStory?
    /// The quiz waiting for the article sheet to finish dismissing — two
    /// sheets can't be on screen at once.
    @State private var pendingQuiz: DailyStory?
    @State private var quizStory: DailyStory?

    func body(content: Content) -> some View {
        content
            .sheet(item: $story, onDismiss: {
                quizStory = pendingQuiz
                pendingQuiz = nil
            }) { story in
                StoryView(story: story, onTakeQuiz: {
                    pendingQuiz = story
                    self.story = nil
                })
            }
            .sheet(item: $quizStory) { story in
                StoryQuizSheet(story: story)
            }
    }
}

/// A story's questions, answered in one go: the learner can change their
/// picks freely, then "Check answers" marks them, saves the score and
/// completes the story.
struct StoryQuizSheet: View {
    @Bindable var story: DailyStory

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Question index → chosen option index.
    @State private var answers: [Int: Int] = [:]
    @State private var isShowingResults = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Did you follow?")
                        .font(.gochiHand(size: 32, relativeTo: .largeTitle))
                        .foregroundStyle(DS.Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(story.title)
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(story.questions.enumerated()), id: \.offset) { index, question in
                        StoryQuestionView(question: question, chosen: answers[index], isRevealed: isShowingResults) { option in
                            answers[index] = option
                        }
                    }
                    if isShowingResults {
                        if let total = story.quizTotal, total > 0 {
                            Text("\(story.quizCorrect ?? 0) of \(total) right")
                                .font(.sniglet(.title3))
                                .foregroundStyle(DS.Color.ink)
                        }
                        Button("Done") { dismiss() }
                            .buttonStyle(.primary)
                    } else {
                        Button("Check answers") { check() }
                            .buttonStyle(.primary)
                            .disabled(answers.count < story.questions.count)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)   // clear of the grabber
            .padding(.bottom, 24)
        }
        .background(DS.Color.paper.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { isShowingResults = story.isCompleted }
    }

    private func check() {
        story.completedAt = .now
        story.quizCorrect = story.questions.enumerated().filter { answers[$0.offset] == $0.element.answerIndex }.count
        story.quizTotal = story.questions.count
        try? context.save()
        withAnimation(.snappy) { isShowingResults = true }
    }
}

/// One quiz question. The learner can switch answers freely; once
/// `isRevealed`, the right answer is ticked and their choice marked.
private struct StoryQuestionView: View {
    let question: StoryQuestion
    let chosen: Int?
    let isRevealed: Bool
    let onChoose: (Int) -> Void

    /// Option fill: just enough ink to read as a tappable row on white.
    private static let optionFill = DS.Color.ink.opacity(0.05)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.sniglet(.headline))
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                let isSelected = !isRevealed && index == chosen
                Button {
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
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.card)
                            .fill(isSelected ? DS.Color.inkTint : Self.optionFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card)
                            .strokeBorder(DS.Color.ink, lineWidth: isSelected ? 1.5 : 0)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Not `.disabled`: that would grey out the answers the
                // learner is meant to be reading.
                .allowsHitTesting(!isRevealed)
                .accessibilityLabel(accessibilityLabel(for: index, option: option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if isRevealed, let chosen {
                Text(chosen == question.answerIndex
                     ? String(localized: "Correct!")
                     : String(localized: "Not quite — it was “\(question.options[question.answerIndex])”."))
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for index: Int) -> String {
        guard isRevealed else { return index == chosen ? "largecircle.fill.circle" : "circle" }
        if index == question.answerIndex { return "checkmark.circle.fill" }
        return index == chosen ? "xmark.circle.fill" : "circle"
    }

    private func tint(for index: Int) -> Color {
        guard isRevealed else { return index == chosen ? DS.Color.ink : .secondary }
        if index == question.answerIndex { return .green }
        return index == chosen ? .red : .secondary
    }

    private func accessibilityLabel(for index: Int, option: String) -> String {
        guard isRevealed else { return option }
        if index == question.answerIndex { return String(localized: "\(option), correct answer") }
        if index == chosen { return String(localized: "\(option), your answer, wrong") }
        return option
    }
}

