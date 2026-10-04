import SwiftUI

/// Full-bleed background used by the incoming and outgoing call screens
/// and the call itself. Deep navy gradient + a thin material veil for the
/// frosted-glass quality. Reused so all three look identical.
///
/// Deliberately plain: the ambient rising bubbles this used to carry
/// competed with the speech bubbles in front of it.
///
/// The backdrop is rendered as an overlay (not a sheet), so it owns its
/// own ultra-thin-material layer to blur whatever app UI sits behind it.
struct CallBackdrop: View {
    var body: some View {
        ZStack {
            // Frosted glass over the app UI behind the call — mirrors
            // the iOS native incoming-call effect where the underlying
            // screen blurs out as the call arrives.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Deep navy gradient — darker than DS.Color.ink so it reads
            // as "incoming call, world goes quiet" rather than just
            // "another blue screen." Tuned down to ~0.78 so the
            // material blur of the app behind reads through clearly.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.26),   // top: dark navy
                    Color(red: 0.01, green: 0.03, blue: 0.12),   // bottom: near-black blue
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.78)
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
        }
    }
}

#Preview {
    CallBackdrop()
}
