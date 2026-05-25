import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Chat bubble with built-in tap-to-toggle translation. Tap once to
/// swap the original-language text for its English translation in
/// place; tap again to swap back. A small "EN" badge in the corner
/// indicates when you're viewing the translation so it's never
/// ambiguous what you're reading.
///
/// The first tap fetches the translation via `TranslationService` (and
/// caches it in memory); subsequent toggles are instant.
struct MessageBubble: View {
    enum Role {
        case walrus
        case user
    }

    let text: String
    let role: Role

    @State private var isShowingTranslation: Bool = false
    @State private var translation: String?
    @State private var isLoading: Bool = false

    var body: some View {
        let displayedText = (isShowingTranslation && translation != nil)
            ? (translation ?? text)
            : text

        styledLabel(displayedText)
            .overlay(alignment: .topTrailing) {
                if isShowingTranslation || isLoading {
                    badge
                        .offset(x: 4, y: -4)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleTranslation()
            }
            .animation(.easeOut(duration: 0.18), value: isShowingTranslation)
            .animation(.easeOut(duration: 0.18), value: isLoading)
    }

    @ViewBuilder
    private func styledLabel(_ string: String) -> some View {
        switch role {
        case .walrus:
            Text(string).walrusBubbleStyle()
        case .user:
            Text(string).userBubbleStyle()
        }
    }

    @ViewBuilder
    private var badge: some View {
        if isLoading {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 22, height: 22)
                .background(Capsule().fill(Color.black.opacity(0.55)))
        } else {
            Text("EN")
                .font(.sniglet(.caption2, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.55)))
        }
    }

    private func toggleTranslation() {
        // Ignore taps that arrive while we're still fetching the first
        // translation — the upcoming flip will land on its own.
        guard !isLoading else { return }
        playHaptic()

        if isShowingTranslation {
            // Already showing English — flip back to the original.
            isShowingTranslation = false
            return
        }
        if translation != nil {
            // Translation in cache — instant flip.
            isShowingTranslation = true
            return
        }
        // First tap on this bubble — fetch, then flip.
        isLoading = true
        Task {
            let result = await TranslationService.shared.translate(text)
            translation = result ?? "Translation unavailable."
            isLoading = false
            isShowingTranslation = true
        }
    }

    private func playHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
