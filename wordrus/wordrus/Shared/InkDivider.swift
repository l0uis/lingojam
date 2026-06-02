import SwiftUI

/// Hairline divider tinted with `DS.Color.inkSeparator`, matching the
/// vocabulary list row separator. Use everywhere instead of plain
/// `Divider()` so all section/row breaks share one visual weight.
///
/// Lives in its own file (rather than `Components.swift`) so the widget
/// extension can include it without dragging in app-only dependencies.
struct InkDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Color.inkSeparator)
            .frame(height: 1)
    }
}
