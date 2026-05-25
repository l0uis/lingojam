import SwiftUI

/// Full-bleed background used by the incoming and outgoing call screens.
/// Deep navy gradient + ambient rising bubbles + a thin material veil
/// for the frosted-glass quality. Reused so both screens look identical.
struct CallBackdrop: View {
    var body: some View {
        ZStack {
            // Deep navy gradient — darker than DS.Color.ink so it reads
            // as "incoming call, world goes quiet" rather than just
            // "another blue screen."
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.26),   // top: dark navy
                    Color(red: 0.01, green: 0.03, blue: 0.12),   // bottom: near-black blue
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Radial vignette darkens the corners further so attention
            // pulls toward the center where the avatar sits.
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.45)],
                center: .center,
                startRadius: 120,
                endRadius: 480
            )
            .ignoresSafeArea()
            .blendMode(.multiply)

            // Ambient rising bubbles — bigger and slower than the chat-
            // bubble version so they read as atmosphere rather than busy.
            BubbleParticleField(
                count: 22,
                tint: .white,
                radiusScale: 2.2,
                speedScale: 0.55
            )
            .opacity(0.45)
            .blur(radius: 0.6)
            .ignoresSafeArea()
        }
    }
}

#Preview {
    CallBackdrop()
}
