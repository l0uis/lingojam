import SwiftUI

/// The Pro paywall, styled as a free-trial timeline ("How your free trial
/// works"). Surfaced when a free user tries to *call* Dr Tusk (incoming
/// calls stay free).
///
/// Purchases route through `Entitlements`, which hides the store backend.
/// The single yearly plan + trial length come from the live RevenueCat
/// Offering (placeholder fallback); the DEBUG ⋯ menu unlocks for testing.
struct PaywallView: View {
    /// Invoked once the user becomes Pro (purchase, restore, or DEBUG
    /// simulate) — lets the presenter continue what the user was doing.
    var onSubscribed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = Entitlements.shared
    @State private var plan: PaywallPlan = .placeholderAnnual
    @State private var isLoadingPlan = true
    @State private var isWorking = false
    @State private var remindBeforeTrialEnds = false

    private var trialDays: Int { plan.trialDays ?? 3 }

    var body: some View {
        ZStack {
            DS.Color.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        timelineCard
                        benefitsCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 56)
                    .padding(.bottom, 16)
                }
                footerArea
            }
        }
        .overlay(alignment: .topLeading) { moreMenu }
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(isWorking)
        .task { await loadPlan() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("How your free trial works")
                .font(.gochiHand(size: 38, relativeTo: .largeTitle))
                .foregroundStyle(Color.whiteboardInk)
                .multilineTextAlignment(.center)
            Text("You won't be charged anything today")
                .font(.sniglet(.callout))
                .foregroundStyle(DS.Color.charcoal)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Timeline

    private struct TrialStep: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        var strikethrough = false
    }

    private var trialSteps: [TrialStep] {
        let now = Date()
        let cal = Calendar.current
        let reminder = cal.date(byAdding: .day, value: max(trialDays - 1, 0), to: now) ?? now
        let end = cal.date(byAdding: .day, value: trialDays, to: now) ?? now
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("ddMMM")
        return [
            TrialStep(icon: "checkmark", title: "Install the app",
                      detail: "Done — you're all set.", strikethrough: true),
            TrialStep(icon: "lock.open.fill", title: "Today — Free trial starts",
                      detail: "Everything unlocked, free."),
            TrialStep(icon: "bell.fill", title: "\(fmt.string(from: reminder)) — Trial reminder",
                      detail: "A heads-up before it ends."),
            TrialStep(icon: "crown.fill", title: "\(fmt.string(from: end)) — Become member",
                      detail: "You go Pro, unless you cancel."),
        ]
    }

    private var timelineCard: some View {
        let steps = trialSteps
        return VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, isLast: index == steps.count - 1)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
    }

    private func stepRow(_ step: TrialStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon + connecting rail (rail fills the rest of the row height so
            // it meets the next row's icon).
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(DS.Color.ink)
                    Image(systemName: step.icon)
                        .font(.sniglet(.subheadline, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                if !isLast {
                    Rectangle()
                        .fill(DS.Color.ink.opacity(0.35))
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(DS.Color.ink)
                    .strikethrough(step.strikethrough, color: DS.Color.ink)
                Text(step.detail)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(DS.Color.charcoal)
            }
            .padding(.bottom, isLast ? 0 : 24)

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Benefits

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Everything in Pro")
                .font(.sniglet(.headline))
                .foregroundStyle(DS.Color.ink)
            benefitRow(icon: "phone.fill", title: "Call Dr Tusk anytime",
                       detail: "He still calls you for free — Pro lets you call him on demand.")
            benefitRow(icon: "globe", title: "Every language",
                       detail: "Switch between all supported languages.")
            benefitRow(icon: "chart.line.uptrend.xyaxis", title: "Every level",
                       detail: "Practise across every CEFR level, A1 to C2.")
            benefitRow(icon: "square.grid.2x2.fill", title: "Every topic",
                       detail: "Unlock all themed decks, not just the basics.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
    }

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.sniglet(.subheadline, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
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

    // MARK: - Footer (sticky)

    private var footerArea: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $remindBeforeTrialEnds) {
                Text("Reminder before trial ends")
                    .font(.sniglet(.headline))
                    .foregroundStyle(DS.Color.charcoal)
            }
            .tint(DS.Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.white)
            )

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
            .disabled(isWorking || isLoadingPlan)

            priceFooter
                .font(.sniglet(.caption))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(
            DS.Color.paper
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.10), radius: 12, y: -4)
        )
    }

    private var ctaTitle: String {
        if let trial = plan.trialText {
            return "Start \(trial) now"
        }
        return "Subscribe"
    }

    /// "€1.99 / mo, billed yearly as **€23.99/year**"
    private var priceFooter: Text {
        var text = Text(plan.priceText).foregroundStyle(.secondary)
        if let billing = plan.billingText {
            text = text
                + Text(", billed yearly as ").foregroundStyle(.secondary)
                + Text(billing).fontWeight(.bold).foregroundStyle(DS.Color.charcoal)
        }
        return text
    }

    // MARK: - Top controls

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .disabled(isWorking)
        .accessibilityLabel("Close")
    }

    /// Secondary actions tucked top-left so they don't compete with the CTA.
    /// Restore is required by App Review; the debug toggle is stripped from
    /// release builds.
    private var moreMenu: some View {
        Menu {
            Button {
                Task { await restore() }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
            }
            #if DEBUG
            Button {
                entitlements.setSimulatedPro(true)
                onSubscribed()
                dismiss()
            } label: {
                Label("Simulate Pro (Debug)", systemImage: "ladybug")
            }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .disabled(isWorking)
        .accessibilityLabel("More options")
    }

    // MARK: - Actions

    private func loadPlan() async {
        let fetched = await entitlements.availablePlans()
        plan = fetched.first(where: { $0.isBestValue }) ?? fetched.first ?? .placeholderAnnual
        isLoadingPlan = false
    }

    private func subscribe() async {
        isWorking = true
        let entitled = await entitlements.purchase(plan)
        if entitled, remindBeforeTrialEnds {
            // Trial just started — remind the user the day before it converts.
            await NotificationService.scheduleTrialEndingReminder(trialDays: trialDays)
        }
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
