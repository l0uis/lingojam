import SwiftUI
import SwiftData

/// A word tapped in a story: what it means and an "Add to stack" action.
///
/// Words from the vocabulary show their own data and join Learning for free
/// (`WordStack.add`). Anything else is looked up through the proxy and saved
/// as a custom word — the existing Add-a-Word flow, which stays Pro-only.
struct StoryWordSheet: View {
    let surface: String
    let word: VocabularyWord?
    let language: TargetLanguage

    @Environment(\.modelContext) private var context
    @State private var entitlements = Entitlements.shared
    @State private var enrichment: WordEnrichmentService.Enrichment?
    @State private var isLookingUp = false
    @State private var lookupFailed = false
    @State private var status: WordStack.Status = .notInStack
    @State private var isShowingPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let word {
                    details(lemma: word.lemma, partOfSpeech: word.partOfSpeech,
                            definition: LocaleService.definition(for: word),
                            example: word.exampleSentence,
                            translation: LocaleService.exampleTranslation(for: word))
                } else if let enrichment {
                    details(lemma: enrichment.lemma, partOfSpeech: enrichment.partOfSpeech,
                            definition: enrichment.definition,
                            example: enrichment.exampleSentence,
                            translation: enrichment.exampleTranslation.isEmpty ? nil : enrichment.exampleTranslation)
                } else if lookupFailed {
                    Text(surface.capitalizedFirst)
                        .font(.gochiHand(size: 38, relativeTo: .largeTitle))
                        .foregroundStyle(Color.whiteboardInk)
                    Text("Couldn't look this word up. Check your connection and try again.")
                        .font(.sniglet(.callout))
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await lookUp() } }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking up “\(surface)”…")
                            .font(.sniglet(.headline))
                    }
                }

                if word != nil || enrichment != nil {
                    stackAction
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
        .task {
            if let word {
                status = WordStack.status(of: word, context: context)
            } else {
                await lookUp()
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(onSubscribed: { Task { await addToStack() } }, source: .myWords)
        }
    }

    private func details(lemma: String, partOfSpeech: String, definition: String, example: String, translation: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lemma.capitalizedFirst)
                    .font(.gochiHand(size: 38, relativeTo: .largeTitle))
                    .foregroundStyle(Color.whiteboardInk)
                if lemma.compare(surface, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                    Text("In the story: “\(surface)”")
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Text(PartOfSpeechLabel.localized(partOfSpeech))
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
                Text(definition)
                    .font(.sniglet(.title3))
                    .padding(.top, 2)
            }
            if !example.isEmpty {
                InkDivider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(example)
                            .font(.sniglet(.title3))
                            .italic()
                        if let translation {
                            Text(translation)
                                .font(.sniglet(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TintedCircleButton(
                        systemImage: "play.fill",
                        tint: .gray,
                        action: { SpeechService.shared.speak(example) },
                        accessibilityLabel: "Play example sentence"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var stackAction: some View {
        switch status {
        case .learning:
            Label("In your stack", systemImage: "checkmark.circle.fill")
                .font(.sniglet(.headline))
                .foregroundStyle(DS.Color.ink)
        case .known, .notInStack:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await addToStack() }
                } label: {
                    Label(status == .known ? "Practise again" : "Add to stack", systemImage: "plus")
                }
                .buttonStyle(.primary)
                if status == .known {
                    Text("You already know this one.")
                        .font(.sniglet(.footnote))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lookUp() async {
        isLookingUp = true
        lookupFailed = false
        enrichment = await WordEnrichmentService.shared.enrich(
            word: surface,
            targetLanguage: language,
            nativeLanguageCode: LocaleService.preferredDefinitionLocale
        )
        isLookingUp = false
        lookupFailed = enrichment == nil
    }

    private func addToStack() async {
        if let word {
            WordStack.add(word, context: context)
        } else if let enrichment {
            guard entitlements.isPro else {
                isShowingPaywall = true
                return
            }
            WordStack.persistCustomWord(enrichment, language: language, context: context)
            Task { await CustomWordSync.pushAll(context: context) }
        }
        withAnimation(.snappy) { status = .learning }
    }
}
