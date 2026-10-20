import SwiftUI

/// Introduces the learner's first story from Dr Tusk: what stories are, and
/// a way straight in. The story is already written — this never shows
/// anything being generated.
struct FirstStorySheet: View {
    let story: DailyStory
    let onRead: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            DrTuskAvatar(size: 76)

            VStack(spacing: 8) {
                Text("Dr Tusk wrote you a story")
                    .font(.gochiHand(size: 30))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every day he writes a short story with the words you're learning. Listen along, and tap any word you don't know.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .foregroundStyle(DS.Color.ink)
                Text(story.title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(Color.whiteboardInk)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background)
            )

            VStack(spacing: 10) {
                Button("Read it now", action: onRead)
                    .buttonStyle(.primary)
                Button {
                    dismiss()
                } label: {
                    Text("Later — it's in the Phone tab")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(DS.Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Color.paper)
    }
}
