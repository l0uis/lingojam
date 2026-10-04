import SwiftUI
import CoreText
import UIKit

extension Font {
    /// Big display font. Currently Shantell Sans (variable font), pinned to weight 450.
    /// Shantell's default instance is Light (300); we drive the `wght` axis directly so
    /// `.weight()` / synthetic bolding aren't needed to get a true 450.
    static func gochiHand(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        Font(shantellUIFont(size: size, weight: 550, relativeTo: style))
    }

    /// Builds Shantell Sans at a chosen point on its `wght` axis, scaled for Dynamic Type.
    private static func shantellUIFont(size: CGFloat, weight: CGFloat, relativeTo style: Font.TextStyle) -> UIFont {
        let wghtAxis = 0x77676874 // 'wght'
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: "ShantellSans-Light",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        let base = UIFont(descriptor: descriptor, size: size)
        return UIFontMetrics(forTextStyle: uiTextStyle(for: style)).scaledFont(for: base)
    }

    private static func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        case .body: return .body
        @unknown default: return .body
        }
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
        "ShantellSans-VariableFont_BNCE,INFM,SPAC,wght",
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
