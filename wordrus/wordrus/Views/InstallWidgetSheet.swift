import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct InstallWidgetSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    widgetPreview
                        .padding(.top, 16)
                    stepsList
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Add widget")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.sniglet(.body))
                }
            }
            .safeAreaInset(edge: .bottom) {
                addWidgetButton
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(DS.Color.paper)
            }
        }
    }

    // MARK: - Widget preview

    private var widgetPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
            mediumContent
                .padding(16)
            walrus
        }
        .frame(width: 360, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hola")
                    .font(.gochiHand(size: 34, relativeTo: .title))
                    .foregroundStyle(Color.whiteboardInk)
                Text("hello")
                    .font(.sniglet(.callout))
            }
            InkDivider()
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hola, ¿cómo estás?")
                    .font(.sniglet(.subheadline).italic())
                    .lineLimit(2)
                Text("Hello, how are you?")
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.trailing, 56)
    }

    private var walrus: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 90)
                .offset(x: 28, y: 56)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Steps

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(
                number: 1,
                title: "Long-press your Home Screen",
                detail: "Press and hold an empty area until the apps start to jiggle."
            )
            step(
                number: 2,
                title: "Tap the + in the top-left",
                detail: "Open the widget gallery from the edit screen."
            )
            step(
                number: 3,
                title: "Search wordrus, then Add Widget",
                detail: "Pick Daily Word and place it on the Home Screen."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.gochiHand(size: 24, relativeTo: .title3))
                .foregroundStyle(Color.whiteboardInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.sniglet(.headline))
                Text(detail)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Add widget CTA

    private var addWidgetButton: some View {
        Button("Add widget", action: addWidgetTapped)
            .buttonStyle(.primary)
    }

    private func addWidgetTapped() {
        dismiss()
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            UIApplication.shared.perform(Selector(("suspend")))
        }
        #endif
    }
}

#Preview {
    InstallWidgetSheet()
}
