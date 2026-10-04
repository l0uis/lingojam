import SwiftUI

/// Compact bottom sheet shown after a call with Walter ends. Replaces
/// the old in-chat "finished footer" so the chat itself can close
/// cleanly. If the user is now eligible for a level-up, the sheet
/// includes the promotion CTA instead of a separate `LevelUpSheet`.
struct CallResultSheet: View {
    let evaluation: ChatEvaluation
    let targetWordCount: Int
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var levelUpAccepted: Bool = false

    /// Eligible if either progression path is complete — the just-finished
    /// call may have been the 2nd pass, or the user may have crossed the
    /// vocabulary threshold earlier and this is the first sheet since.
    private var isEligibleForLevelUp: Bool {
        LevelProgression.status(context: context).eligible
    }

    var body: some View {
        VStack(spacing: 18) {
            statusBadge

            Text(evaluation.encouragement)
                .font(.sniglet(.callout))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            // Nothing to report when the call had no target words — a
            // learner with no reviewed vocabulary yet shouldn't be shown
            // "0 of 0 words used".
            if targetWordCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: evaluation.passed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(evaluation.passed ? .green : .secondary)
                    Text("\(evaluation.elicitedWordIDs.count) of \(targetWordCount) words used")
                        .font(.sniglet(.subheadline, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if isEligibleForLevelUp, let next = OnboardingStore.cefrLevel.next {
                levelUpBlock(next: next)
            }

            Button("Done") { finish() }
                .buttonStyle(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var statusBadge: some View {
        let (system, color, title): (String, Color, String) = {
            if evaluation.passed {
                return ("checkmark.seal.fill", .green, "Conversation passed")
            }
            if evaluation.elicitedWordIDs.isEmpty {
                return ("phone.down.fill", .secondary, "Call ended")
            }
            return ("waveform", .blue, "Call ended")
        }()
        return VStack(spacing: 8) {
            Image(systemName: system)
                .font(.sniglet(size: 44))
                .foregroundStyle(color)
            Text(title)
                .font(.gochiHand(size: 28, relativeTo: .title2))
                .foregroundStyle(Color.whiteboardInk)
        }
    }

    private func levelUpBlock(next: CEFRLevel) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Ready for **\(next.title)**")
                    .font(.sniglet(.headline))
            }
            Text(next.subtitle)
                .font(.sniglet(.caption))
                .foregroundStyle(.secondary)
            Button("Move me up to \(next.title)") {
                LevelProgression.promote()
                levelUpAccepted = true
                finish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    private func finish() {
        onDismiss()
        dismiss()
    }
}

#Preview {
    Color.gray.sheet(isPresented: .constant(true)) {
        CallResultSheet(
            evaluation: ChatEvaluation(
                elicitedWordIDs: ["a", "b", "c"],
                passed: true,
                encouragement: "Nice work — you used 3 of the words you've been studying."
            ),
            targetWordCount: 5,
            onDismiss: {}
        )
    }
}
