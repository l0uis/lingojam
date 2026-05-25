import SwiftUI
import CoreText

extension Font {
    static func gochiHand(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("GochiHand-Regular", size: size, relativeTo: style)
    }

    static func sniglet(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        let base: Font = style.map { .custom("Sniglet-Regular", size: size, relativeTo: $0) }
            ?? .custom("Sniglet-Regular", fixedSize: size)
        return base.weight(weight)
    }

    static func sniglet(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font.custom("Sniglet-Regular", size: defaultSize(for: style), relativeTo: style)
            .weight(weight)
    }

    private static func defaultSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}

enum FontRegistrar {
    private static let fontFileNames = [
        "GochiHand-Regular",
        "Sniglet-Regular",
    ]
    private static var didRegister = false

    static func registerOnce() {
        guard !didRegister else { return }
        didRegister = true
        for name in fontFileNames {
            register(name: name)
        }
    }

    private static func register(name: String) {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "ttf"),
            bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            print("⚠️ FontRegistrar: \(name).ttf not found in bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            print("⚠️ FontRegistrar: failed to register \(name): \(desc)")
        } else {
            print("✅ FontRegistrar: registered \(name) from \(url.lastPathComponent)")
        }
    }
}
