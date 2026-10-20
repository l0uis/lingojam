import SwiftUI

/// The bonus card dealt in as the daily set's last card every few days: one
/// idiom, untranslatable word, false friend or literal compound in the
/// learner's language, with Dr Tusk's aside. Swiped away like a word but
/// never rated. A small share button exports a post-ready 9:16 image.
/// Sized like the word cards so it sits in the stack; the deck owns the swipe.
struct CuriosityCard: View {
    let curiosity: Curiosity
    let language: TargetLanguage

    @State private var shareImage: UIImage?

    var body: some View {
        // Small phones drop the example sentence before anything gets squeezed.
        ViewThatFits(in: .vertical) {
            content(showsExample: true)
            content(showsExample: false)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
        .task(id: curiosity.id) {
            shareImage = CuriosityShareImage.render(curiosity, language: language)
        }
    }

    private func content(showsExample: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            phraseBlock
            if showsExample {
                InkDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(curiosity.example)
                        .font(.sniglet(.title3))
                        .italic()
                    Text(curiosity.exampleTranslation)
                        .font(.sniglet(.body))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            quipRow
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(language.flagAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Dr Tusk's curiosity")
                    .font(.sniglet(.subheadline, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                Text(curiosity.kind.label)
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            circleButton(systemImage: "speaker.wave.2.fill", label: "Play pronunciation") {
                SpeechService.shared.speak(curiosity.phrase)
            }
            shareButton
        }
    }

    private var phraseBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sized so the longest word fits a small phone's card on one line.
            Text(curiosity.phrase)
                .font(.gochiHand(size: curiosity.phraseFontSize(base: 30, width: 250)))
                .foregroundStyle(Color.whiteboardInk)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let looksLike = curiosity.looksLike {
                (Text("looks like ").foregroundStyle(.secondary)
                    + Text(looksLike).strikethrough().foregroundStyle(.secondary))
                    .font(.sniglet(.callout))
            }
            if let literal = curiosity.literal {
                (Text("literally ").foregroundStyle(.secondary)
                    + Text(literal).foregroundStyle(DS.Color.coralDeep))
                    .font(.sniglet(.title3))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if curiosity.kind == .falseFriend {
                    Text("actually means ") + Text(curiosity.meaning).foregroundStyle(DS.Color.coralDeep)
                } else {
                    Text("= \(curiosity.meaning)")
                }
            }
            .font(.sniglet(.title3))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shares the 9:16 post image with the App Store link. Appears once the
    /// image has rendered (a beat after the card first shows).
    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            let image = Image(uiImage: shareImage)
            ShareLink(
                item: image,
                subject: Text(curiosity.phrase),
                message: Text(CuriosityShareImage.message(for: curiosity)),
                preview: SharePreview(curiosity.phrase, image: image)
            ) {
                circleLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")
            .simultaneousGesture(TapGesture().onEnded {
                Analytics.capture(.curiosityShareTapped, ["curiosity": curiosity.id])
            })
        }
    }

    private func circleButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func circleLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.sniglet(.body))
            .foregroundStyle(DS.Color.ink)
            .frame(width: 40, height: 40)
            .background(Circle().fill(DS.Color.inkTint))
    }

    /// Dr Tusk's aside in a bubble, with him peeking up beside it.
    private var quipRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(curiosity.quip)
                .font(.sniglet(.callout))
                .foregroundStyle(DS.Color.charcoal)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Color.paper))
                .frame(maxWidth: .infinity, alignment: .leading)
            Image("walrus")
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 64, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
extension CuriosityCard {
    /// The card with id `id` on the deck's paper, for visual QA (see the
    /// `-uiPreviewCuriosity` launch argument).
    @ViewBuilder
    static func debugPreview(id: String) -> some View {
        let languages: [TargetLanguage] = [.spanish, .french, .german, .italian]
        if let language = languages.first(where: { id.hasPrefix($0.languageCode + "-") }),
           let item = CuriosityService.all(for: language).first(where: { $0.id == id }) {
            CuriosityCard(curiosity: item, language: language)
                .padding(.horizontal, 24)
                .padding(.top, 150)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(DS.Color.paper)
                .preferredColorScheme(.light)
        } else {
            Text(verbatim: "No curiosity \(id)")
        }
    }
}
#endif

extension Curiosity.Kind {
    var label: String {
        switch self {
        case .idiom: String(localized: "Idiom")
        case .untranslatable: String(localized: "No English word")
        case .falseFriend: String(localized: "False friend")
        case .literal: String(localized: "Literally")
        }
    }
}

/// The 9:16 share image (1080×1920), in the TikTok posts' style: brand blue,
/// the phrase big in Dr Tusk's handwriting, his aside in a bubble beside him,
/// and the Wordrus wordmark. Laid out top to bottom so long phrases push
/// Dr Tusk down rather than run under him.
struct CuriosityShareImage: View {
    let curiosity: Curiosity
    let language: TargetLanguage

    /// The posts' blue (#0B3A86), a touch deeper than the ink.
    private static let blue = Color(red: 0x0B / 255.0, green: 0x3A / 255.0, blue: 0x86 / 255.0)
    private static let mutedOnBlue = Color(red: 0xB9 / 255.0, green: 0xC9 / 255.0, blue: 0xEC / 255.0)

    @MainActor
    static func render(_ curiosity: Curiosity, language: TargetLanguage) -> UIImage? {
        let renderer = ImageRenderer(content: CuriosityShareImage(curiosity: curiosity, language: language))
        renderer.scale = 3
        return renderer.uiImage
    }

    #if DEBUG
    /// Visual QA: write every bundled curiosity's share image to `dir`
    /// (see the `-uiRenderCuriosities` launch argument).
    @MainActor
    static func renderAll(to dir: String) {
        for language in [TargetLanguage.spanish, .french, .german, .italian] {
            for item in CuriosityService.all(for: language) {
                guard let png = render(item, language: language)?.pngData() else { continue }
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(item.id).png"))
            }
        }
    }
    #endif

    static func message(for curiosity: Curiosity) -> String {
        String(localized: "\(curiosity.phrase) = \(curiosity.meaning). Learning languages with Dr Tusk on Wordrus: \(AppStoreLinks.productURL.absoluteString)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("wordrusLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 18)
                    .foregroundStyle(.white)
                Spacer()
                Image(language.flagAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
            }
            .padding(.bottom, 30)

            Text(curiosity.kind.shareTitle)
                .font(.sniglet(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.14)))
                .padding(.bottom, 14)

            Text(curiosity.phrase)
                .font(.gochiHand(size: curiosity.phraseFontSize(base: 42, width: 300)))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)

            if let looksLike = curiosity.looksLike {
                label("looks like").padding(.top, 14)
                Text(looksLike)
                    .font(.gochiHand(size: 24))
                    .strikethrough(color: DS.Color.coralDeep)
                    .foregroundStyle(Self.mutedOnBlue)
                label("actually means").padding(.top, 8)
                Text(curiosity.meaning)
                    .font(.gochiHand(size: 26))
                    .foregroundStyle(DS.Color.coralDeep)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let literal = curiosity.literal {
                    label("literally").padding(.top, 14)
                    Text(literal)
                        .font(.gochiHand(size: 26))
                        .foregroundStyle(DS.Color.coralDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("= \(curiosity.meaning)")
                    .font(.sniglet(size: 19))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Spacer(minLength: 12)

            // Dr Tusk standing at the bottom edge, his aside beside his head.
            HStack(alignment: .top, spacing: 6) {
                Text(curiosity.quip)
                    .font(.sniglet(size: 15))
                    .foregroundStyle(DS.Color.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                Image("walrus")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 140, alignment: .top)
                    .clipped()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 72)
        .frame(width: 360, height: 640, alignment: .topLeading)
        .background(Self.blue)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.sniglet(size: 13))
            .foregroundStyle(Self.mutedOnBlue)
    }
}

extension Curiosity {
    /// Point size, capped at `base`, at which the phrase's longest word fits
    /// on one line `width` points wide in Dr Tusk's handwriting — so a long
    /// compound like "Backpfeifengesicht" shrinks instead of breaking mid-word.
    func phraseFontSize(base: CGFloat, width: CGFloat) -> CGFloat {
        let longest = phrase.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 1
        // Shantell at this weight averages about 0.66em per letter.
        return min(base, width / (CGFloat(longest) * 0.66))
    }
}

private extension Curiosity.Kind {
    /// The pill above the phrase on the share image.
    var shareTitle: String {
        switch self {
        case .idiom: String(localized: "Idioms that make no sense in English")
        case .untranslatable: String(localized: "A word English doesn't have")
        case .falseFriend: String(localized: "False friend alert")
        case .literal: String(localized: "Taken literally")
        }
    }
}

#Preview("Card") {
    let item = CuriosityService.all(for: .spanish).first!
    return CuriosityCard(curiosity: item, language: .spanish)
        .padding(24)
        .background(DS.Color.paper)
}

#Preview("Share image") {
    CuriosityShareImage(curiosity: CuriosityService.all(for: .german).first!, language: .german)
}
