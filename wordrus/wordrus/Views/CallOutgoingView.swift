import SwiftUI

/// "Calling Walter…" screen shown when the user initiates a call. Holds
/// the user on a ringing animation for a few seconds, then fires
/// `onAnswered` so the host can transition to the chat. Tapping the red
/// button dismisses without recording a session.
struct CallOutgoingView: View {
    let onAnswered: () -> Void
    let onCancel: () -> Void

    /// Fixed pickup delay in seconds, timed to the `sceneSleep` clip so the
    /// call connects right as Dr Tusk jolts awake. Retime it if the clip
    /// changes.
    private static let pickupDelay: Double = 3.5

    @State private var ringPulse: CGFloat = 1.0
    @State private var dotPhase: Int = 0
    @State private var hasAnswered: Bool = false

    var body: some View {
        ZStack {
            CallBackdrop()

            VStack(spacing: 28) {
                Spacer()

                Text("Calling")
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                Text("Dr Tusk")
                    .font(.gochiHand(size: 48, relativeTo: .largeTitle))
                    .foregroundStyle(.white)

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 2)
                        .frame(width: 280, height: 280)
                        .scaleEffect(ringPulse)
                        .opacity(2 - ringPulse)
                    // Dr Tusk dozing until he picks up. The clip carries its
                    // own transparency, so it sits straight on the backdrop.
                    LoopingVideoView(dataAssetName: "sceneSleep", pauseBetweenLoops: 2, dropsWhiteBackground: false)
                        .frame(width: 320, height: 320)
                        .accessibilityHidden(true)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        ringPulse = 1.6
                    }
                }

                Text(ringingLabel)
                    .font(.sniglet(.callout))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()

                Spacer()

                VStack(spacing: 8) {
                    Button(action: cancel) {
                        Image(systemName: "phone.down.fill")
                            .font(.sniglet(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(.red))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    Text("Cancel")
                        .font(.sniglet(.caption))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 32)
        }
        .task { await waitThenAnswer() }
        .task { await animateDots() }
        .statusBarHidden(true)
    }

    private var ringingLabel: LocalizedStringResource {
        let dots = String(repeating: ".", count: dotPhase)
        return LocalizedStringResource("Ringing\(dots)", comment: "Outgoing call status; the argument is 0–3 animated dots.")
    }

    private func waitThenAnswer() async {
        try? await Task.sleep(nanoseconds: UInt64(Self.pickupDelay * 1_000_000_000))
        guard !hasAnswered else { return }
        hasAnswered = true
        onAnswered()
    }

    private func animateDots() async {
        while !hasAnswered {
            try? await Task.sleep(nanoseconds: 500_000_000)
            dotPhase = (dotPhase + 1) % 4
        }
    }

    private func cancel() {
        hasAnswered = true
        onCancel()
    }
}

#Preview {
    CallOutgoingView(onAnswered: {}, onCancel: {})
}
