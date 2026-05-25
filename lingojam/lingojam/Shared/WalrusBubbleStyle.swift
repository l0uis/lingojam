import SwiftUI

/// Liquid-look bubble style with a vertical gradient, soft surface
/// highlight, and rising bubble particles inside. Two themes:
///   - `.userBubbleStyle()`  → dark blue liquid (the speaker)
///   - `.walrusBubbleStyle()` → opaque white liquid (Walter)
///
/// Shared between [ChatView] live bubbles and the conversation detail
/// sheet so both surfaces stay in lock-step.

private enum LiquidBubbleTheme {
    case blue   // user — dark navy, white text, white particles
    case white  // Walter — opaque white, ink text, soft blue particles

    var gradient: LinearGradient {
        switch self {
        case .blue:
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.23, green: 0.36, blue: 0.70), location: 0.0),
                    .init(color: Color(red: 0.10, green: 0.22, blue: 0.50), location: 0.55),
                    .init(color: Color(red: 0.03, green: 0.09, blue: 0.28), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .white:
            LinearGradient(
                stops: [
                    .init(color: Color.white, location: 0.0),
                    .init(color: Color(red: 0.94, green: 0.96, blue: 0.99), location: 0.55),
                    .init(color: Color(red: 0.84, green: 0.89, blue: 0.96), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var textColor: Color {
        switch self {
        case .blue: .white
        case .white: DS.Color.ink
        }
    }

    var highlight: LinearGradient {
        switch self {
        case .blue:
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        case .white:
            LinearGradient(
                colors: [Color.white.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    var strokeColor: Color {
        switch self {
        case .blue: Color.white.opacity(0.08)
        case .white: DS.Color.ink.opacity(0.12)
        }
    }

    var shadowColor: Color {
        switch self {
        case .blue: DS.Color.ink.opacity(0.18)
        case .white: Color.black.opacity(0.08)
        }
    }
}

private struct LiquidBubbleStyle: ViewModifier {
    let theme: LiquidBubbleTheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return content
            .foregroundStyle(theme.textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    shape.fill(theme.gradient)
                    // Soft highlight near the top edge — reads as light
                    // catching the surface of the liquid.
                    shape.fill(theme.highlight)
                }
            }
            .overlay(
                shape.stroke(theme.strokeColor, lineWidth: 0.5)
            )
            .shadow(color: theme.shadowColor, radius: 4, y: 2)
    }
}

extension View {
    /// White, opaque liquid bubble — Walter's voice.
    func walrusBubbleStyle() -> some View {
        modifier(LiquidBubbleStyle(theme: .white))
    }

    /// Dark blue liquid bubble — the user's voice.
    func userBubbleStyle() -> some View {
        modifier(LiquidBubbleStyle(theme: .blue))
    }
}

// MARK: - Particle field

/// Soft rising-bubble particle effect rendered via `TimelineView` +
/// `Canvas`. Particle properties are derived from the index with a
/// cheap hash so they stay stable across redraws — only positions
/// animate. Self-contained and clip-safe; apply a `.clipShape` from
/// the parent to keep particles inside the bubble.
///
/// Internal so the call screens can reuse it as ambient background
/// decoration, not just inside chat bubbles.
struct BubbleParticleField: View {
    var count: Int = 14
    var tint: Color = .white
    var radiusScale: Double = 1.0
    var speedScale: Double = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<count {
                    let spec = particleSpec(index: i)
                    var progress = (t * spec.speed + spec.phase).truncatingRemainder(dividingBy: 1.0)
                    if progress < 0 { progress += 1 }

                    // Drift particles side-to-side slightly so they don't
                    // just rise in perfect vertical lines.
                    let xJitter = sin((t + spec.phase * 7) * 0.6) * 3
                    let x = size.width * spec.xFraction + xJitter
                    let y = size.height * (1 - progress)
                    let fade = sin(progress * .pi) // 0 at edges, 1 in middle
                    let r = spec.radius
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)

                    // Bubble fill — soft white at low alpha.
                    ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(fade * 0.30)))
                    // Highlight stroke for a "shiny" bubble feel.
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(tint.opacity(fade * 0.45)),
                        lineWidth: 0.5
                    )
                }
            }
        }
    }

    private struct Particle {
        let xFraction: Double
        let radius: Double
        let speed: Double
        let phase: Double
    }

    /// Cheap deterministic pseudo-random per particle index. The
    /// `fract(sin(x))` trick is the same one used in GPU shaders —
    /// no actual randomness needed, just stable per-index variation.
    private func particleSpec(index: Int) -> Particle {
        let seed = Double(index) + 1
        return Particle(
            xFraction: 0.05 + hash(seed * 12.9898) * 0.90,
            radius: (1.5 + hash(seed * 78.233) * 3.5) * radiusScale,
            speed: (0.06 + hash(seed * 39.346) * 0.10) * speedScale,
            phase: hash(seed * 95.123)
        )
    }

    private func hash(_ x: Double) -> Double {
        let v = sin(x) * 43758.5453
        return v - floor(v)
    }
}
