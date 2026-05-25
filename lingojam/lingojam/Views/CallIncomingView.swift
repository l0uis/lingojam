import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// "Walter is calling" screen that fronts a chat session. Leans into the
/// phone-call metaphor so the chat feels like an event, not a chore.
struct CallIncomingView: View {
    let onAnswer: () -> Void
    let onDecline: () -> Void

    @State private var pulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            CallBackdrop()

            VStack(spacing: 28) {
                Spacer()

                Text("Incoming call")
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                Text("Walter")
                    .font(.gochiHand(size: 48, relativeTo: .largeTitle))
                    .foregroundStyle(.white)

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 220, height: 220)
                        .scaleEffect(pulse)
                        .opacity(2 - pulse)
                    Circle()
                        .fill(.white)
                        .frame(width: 180, height: 180)
                    Image("walrus")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = 1.6
                    }
                }

                Text("Wants to practice with you")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                HStack(spacing: 56) {
                    callButton(
                        systemImage: "phone.down.fill",
                        background: .red,
                        label: "Decline",
                        action: onDecline
                    )
                    callButton(
                        systemImage: "phone.fill",
                        background: .green,
                        label: "Answer",
                        action: {
                            playHaptic()
                            onAnswer()
                        }
                    )
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 32)
        }
    }

    private func callButton(
        systemImage: String,
        background: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.sniglet(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(background))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.sniglet(.caption))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func playHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

#Preview {
    CallIncomingView(onAnswer: {}, onDecline: {})
}
