import SwiftUI

/// The word shown when the user taps a widget, Live Activity, or reminder
/// notification. Presented from `RootView` as a sheet so it overlaps whatever
/// tab / screen the user was on. Read-only by design — its whole job is to
/// surface *this* word; reviewing and editing live on the Deck and Words tabs.
struct DeepLinkWordSheet: View {
    let word: VocabularyWord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.lemma.capitalizedFirst)
                        .font(.gochiHand(size: 42))
                        .foregroundStyle(Color.whiteboardInk)
                    Text(word.partOfSpeech)
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                    Text(LocaleService.definition(for: word))
                        .font(.sniglet(.title3))
                        .padding(.top, 2)
                }

                if !word.exampleSentence.isEmpty {
                    InkDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(word.exampleSentence)
                                .font(.sniglet(.title2))
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TintedCircleButton(
                                systemImage: "play.fill",
                                tint: .gray,
                                action: { SpeechService.shared.speak(word.exampleSentence) },
                                accessibilityLabel: "Play example sentence"
                            )
                        }
                        if let translation = LocaleService.exampleTranslation(for: word) {
                            Text(translation)
                                .font(.sniglet(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }
}
