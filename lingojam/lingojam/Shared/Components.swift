import SwiftUI

/// Filled primary action button — dark ink blue, full-width, with a soft
/// shadow and an inset highlight stroke for a vibrant, raised look.
///
/// Usage:
/// ```
/// Button("Continue", action: onContinue)
///     .buttonStyle(.primary)
/// ```
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.sniglet(.headline))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: DS.Size.buttonMinHeight)
            .padding(.horizontal, DS.Size.buttonHorizontalPadding)
            .background(Capsule(style: .continuous).fill(DS.Color.ink))
            .overlay(
                // Inset highlight stroke — sits inside the capsule so
                // edges read crisp and the button feels dimensional.
                Capsule(style: .continuous)
                    .strokeBorder(DS.Color.inkHighlight.opacity(0.55), lineWidth: 1)
            )
            .shadow(
                color: isEnabled ? DS.Shadow.buttonColor : .clear,
                radius: pressed ? 2 : DS.Shadow.buttonRadius,
                y: pressed ? 1 : DS.Shadow.buttonY
            )
            .scaleEffect(pressed ? 0.98 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.5)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

// MARK: - Pill button

/// Filter-pill button style. Selected pills are filled ink with white
/// text; unselected pills sit on the quiet ink-tint surface with ink
/// text. Used by tag-style filters (e.g. POS chips in Vocabulary).
struct PillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sniglet(.subheadline, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? DS.Color.ink : DS.Color.inkTint)
            )
            .foregroundStyle(isSelected ? Color.white : DS.Color.ink)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(selected: Bool) -> PillButtonStyle {
        PillButtonStyle(isSelected: selected)
    }
}

// MARK: - Tinted circle button

/// Round 56pt icon button — colored icon on a matching tinted circle.
/// Used for the jam card sound toggle and the word-detail action row.
struct TintedCircleButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var accessibilityLabel: String? = nil
    var size: CGFloat = 56

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.sniglet(.title3))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

// MARK: - Tinted surface

extension View {
    /// Wraps the content in a light-blue rounded-rectangle surface — the
    /// canonical "quiet stat card" look. Padding defaults match the
    /// vocabulary count banner; override per call site if needed.
    func tintedSurface(
        cornerRadius: CGFloat = DS.Radius.surface,
        horizontalPadding: CGFloat = 20,
        verticalPadding: CGFloat = 14
    ) -> some View {
        self
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DS.Color.inkTint)
            )
    }
}

// MARK: - Settings toolbar

private struct SettingsToolbarModifier: ViewModifier {
    let placement: ToolbarItemPlacement
    let onRestartOnboarding: () -> Void
    @State private var isShowingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: placement) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    SettingsView(onRestartOnboarding: {
                        isShowingSettings = false
                        onRestartOnboarding()
                    })
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
                }
            }
    }
}

extension View {
    /// Adds a gear button to the navigation bar that opens Settings in a
    /// sheet. Apply once per top-level tab view. Defaults to leading so the
    /// gear groups into the same pill as the deck/language filter.
    func settingsToolbar(
        placement: ToolbarItemPlacement = .topBarLeading,
        onRestartOnboarding: @escaping () -> Void
    ) -> some View {
        modifier(SettingsToolbarModifier(
            placement: placement,
            onRestartOnboarding: onRestartOnboarding
        ))
    }

    /// Standard table-section-header style: Sniglet footnote, grey, uppercase.
    /// Apply to the `Text` inside a `Section`'s `header:` block so all
    /// grouped lists share one heading treatment.
    func sectionHeaderStyle() -> some View {
        font(.sniglet(.footnote))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Inline navigation title styled with the GochiHand display font.
    func gochiHandNavigationTitle(_ title: String, size: CGFloat = 26) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.gochiHand(size: size, relativeTo: .title))
                        .foregroundStyle(Color.whiteboardInk)
                }
            }
    }
}
