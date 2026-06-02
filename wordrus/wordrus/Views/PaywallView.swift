import SwiftUI

/// The Pro paywall. Surfaced when a free user tries to *call* Dr Tusk
/// (incoming calls stay free). Pitch: call on demand + the whole library.
///
/// Purchases route through `Entitlements`, which hides the store backend.
/// Until RevenueCat is wired in, plans render from `PaywallPlan.placeholders`
/// and the DEBUG "Simulate Pro" button unlocks for testing.
struct PaywallView: View {
    /// Invoked once the user becomes Pro (purchase, restore, or DEBUG
    /// simulate). The presenter can use this to continue what the user was
    /// trying to do — e.g. immediately place the call they tapped.
    var onSubscribed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = Entitlements.shared
    @State private var selectedPlan: PaywallPlan = .placeholderAnnual
    @State private var isWorking = false

    private let plans = PaywallPlan.placeholders

    var body: some View {
        ZStack {
            DS.Color.paper.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    hero
                    benefits
                    planPicker
                    callToAction
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 116, height: 116)
                    .overlay(Circle().stroke(DS.Color.ink.opacity(0.12), lineWidth: 1))
                Image("walrus")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 104)
            }
            Text("Dr Tusk Pro")
                .font(.gochiHand(size: 40, relativeTo: .largeTitle))
                .foregroundStyle(Color.whiteboardInk)
            Text("Call Dr Tusk whenever you want — and unlock every language, level and topic.")
                .font(.sniglet(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.top, 24)
    }

    // MARK: - Benefits

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefitRow(
                icon: "phone.fill",
                title: "Call Dr Tusk anytime",
                detail: "He still calls you for free — Pro lets you call him on demand."
            )
            benefitRow(
                icon: "globe",
                title: "Every language",
                detail: "Switch between all supported languages, not just one."
            )
            benefitRow(
                icon: "chart.line.uptrend.xyaxis",
                title: "Every level",
                detail: "Practise across every CEFR level, A1 to C2."
            )
            benefitRow(
                icon: "square.grid.2x2.fill",
                title: "Every topic",
                detail: "Unlock all themed decks beyond the general set."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                .fill(DS.Color.inkTint)
        )
    }

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.sniglet(.headline))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(DS.Color.ink))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(DS.Color.charcoal)
                Text(detail)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(spacing: 12) {
            ForEach(plans) { plan in
                planRow(plan)
            }
        }
    }

    private func planRow(_ plan: PaywallPlan) -> some View {
        let isSelected = plan == selectedPlan
        return Button {
            selectedPlan = plan
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.sniglet(.title3))
                    .foregroundStyle(isSelected ? DS.Color.ink : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.sniglet(.headline))
                            .foregroundStyle(DS.Color.charcoal)
                        if plan.isBestValue {
                            Text("BEST VALUE")
                                .font(.sniglet(.caption2, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DS.Color.ink))
                        }
                    }
                    if let subtitle = plan.subtitle {
                        Text(subtitle)
                            .font(.sniglet(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(plan.priceText)
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(DS.Color.charcoal)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? DS.Color.ink : DS.Color.ink.opacity(0.12),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Call to action

    private var callToAction: some View {
        VStack(spacing: 10) {
            Button {
                Task { await subscribe() }
            } label: {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(ctaTitle)
                }
            }
            .buttonStyle(.primary)
            .disabled(isWorking)

            Button {
                Task { await restore() }
            } label: {
                Text("Restore purchases")
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(DS.Color.ink)
            }
            .disabled(isWorking)

            #if DEBUG
            Button {
                entitlements.setSimulatedPro(true)
                onSubscribed()
                dismiss()
            } label: {
                Text("Simulate Pro (debug)")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            #endif
        }
    }

    private var ctaTitle: String {
        selectedPlan.subtitle?.localizedCaseInsensitiveContains("trial") == true
            ? "Start free trial"
            : "Subscribe"
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Auto-renews until cancelled. Cancel anytime in Settings.")
            .font(.sniglet(.caption2))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .disabled(isWorking)
        .accessibilityLabel("Close")
    }

    // MARK: - Actions

    private func subscribe() async {
        isWorking = true
        let entitled = await entitlements.purchase(selectedPlan)
        isWorking = false
        if entitled {
            onSubscribed()
            dismiss()
        }
    }

    private func restore() async {
        isWorking = true
        let restored = await entitlements.restore()
        isWorking = false
        if restored {
            onSubscribed()
            dismiss()
        }
    }
}

#Preview {
    PaywallView()
}
