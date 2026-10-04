import SwiftUI

/// Central design tokens — colors, sizing, radii, shadows.
/// Adjust values here to update the visual language app-wide.
enum DS {
    enum Color {
        /// Dark handwriting blue used throughout the whiteboard UI.
        /// Also exposed as `SwiftUI.Color.whiteboardInk` for legacy call sites.
        static let ink = SwiftUI.Color(red: 0.10, green: 0.22, blue: 0.50)

        /// Slightly lighter ink — used for inner stroke highlights on filled
        /// surfaces to give a more vibrant, dimensional feel.
        static let inkHighlight = SwiftUI.Color(red: 0.32, green: 0.46, blue: 0.78)

        /// Quiet light-blue surface tint — used as the background for
        /// unselected pills, tinted stat cards, and other low-emphasis
        /// surfaces that still need to read as part of the ink palette.
        static let inkTint = ink.opacity(0.12)

        /// Hairline ink-tinted divider used between list rows.
        static let inkSeparator = ink.opacity(0.05)

        /// Warm cream page color — the main content background, evoking
        /// notebook paper behind handwritten ink. (#F8F2E9)
        static let paper = SwiftUI.Color(red: 0xF8 / 255.0, green: 0xF2 / 255.0, blue: 0xE9 / 255.0)

        /// A shade darker than `paper`, same warm hue — a backdrop panel that
        /// still reads as part of the page. (#EDE4D6)
        static let paperShade = SwiftUI.Color(red: 0xED / 255.0, green: 0xE4 / 255.0, blue: 0xD6 / 255.0)

        /// Near-black charcoal for secondary descriptive copy (sublines under
        /// titles) that should read as high-contrast body text, not muted gray.
        static let charcoal = SwiftUI.Color(red: 0.13, green: 0.13, blue: 0.15)
    }

    enum Radius {
        static let card: CGFloat = 14
        /// Default radius for tinted stat surfaces and grouped banners.
        static let surface: CGFloat = 20
    }

    enum Size {
        static let buttonMinHeight: CGFloat = 56
        static let buttonHorizontalPadding: CGFloat = 22
    }

    enum Shadow {
        /// Soft elevation tinted with ink so the shadow feels part of the
        /// blue, not a generic gray drop.
        static let buttonColor = DS.Color.ink.opacity(0.28)
        static let buttonRadius: CGFloat = 8
        static let buttonY: CGFloat = 3
    }
}

extension Color {
    /// Legacy alias — prefer `DS.Color.ink` in new code.
    static let whiteboardInk = DS.Color.ink
}

extension String {
    /// Returns the string with only its first character uppercased,
    /// leaving the rest unchanged. Used for displaying vocabulary lemmas.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
