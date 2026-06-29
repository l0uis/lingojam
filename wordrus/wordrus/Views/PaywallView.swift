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
    /// True when the live plans couldn't be fetched — we show a Retry instead
    /// of a CTA that would buy nothing, and avoid presenting placeholder prices
    /// as if they were real.
    @State private var planLoadFailed = false
    @State private var alert: PaywallAlert?

    /// Configured free-trial length, or nil when the store product has no
    /// introductory free-trial offer. Never fabricated — the paywall must not
    /// advertise a trial the App Store payment sheet won't honour (2.1(b)).
    private var trialDays: Int? { plan.trialDays }

    /// A user-facing message surfaced when a purchase/restore needs feedback.
    private struct PaywallAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        ZStack {
            DS.Color.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        if plan.trialDays != nil { timelineCard }
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
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Header

    private var header: some View {
        Text("Unlock Wordrus Pro")
            .font(.gochiHand(size: 38, relativeTo: .largeTitle))
            .foregroundStyle(Color.whiteboardInk)
            .multilineTextAlignment(.center)
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
        let days = plan.trialDays ?? 0
        let reminder = cal.date(byAdding: .day, value: max(days - 1, 0), to: now) ?? now
        let end = cal.date(byAdding: .day, value: days, to: now) ?? now
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("ddMMM")
        return [
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
            benefitRow(icon: "text.badge.plus", title: "Add your own words",
                       detail: "Look up any word you hear or see — definition and example added instantly.")
            benefitRow(icon: "globe", title: "Every language",
                       detail: "Switch between all supported languages.")
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
            if planLoadFailed {
                Button {
                    Task { await retryLoadPlan() }
                } label: {
                    if isLoadingPlan {
                        ProgressView().tint(.white)
                    } else {
                        Text("Retry")
                    }
                }
                .buttonStyle(.primary)
                .disabled(isLoadingPlan)

                Text("Couldn't load subscription details. Check your connection and try again.")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                priceBlock

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

                Text(billingNote)
                    .font(.sniglet(.caption))
                    .foregroundStyle(DS.Color.charcoal)
                    .multilineTextAlignment(.center)
            }

            legalLinks
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
        plan.trialDays.map { "Start \($0)-day free trial" } ?? "Subscribe"
    }

    /// Small print under the CTA. Clarifies the billing cadence.
    private var billingNote: String {
        plan.billingText != nil ? "Billed annually. Cancel anytime." : "Cancel anytime."
    }

    /// Pricing block: the total billed amount is the most clear and
    /// conspicuous element (large, in our blue), with the free-trial and
    /// calculated per-month framing in a subordinate size and colour beneath
    /// it. Required by Guideline 3.1.2(c) — introductory/calculated pricing
    /// must not be more prominent than the amount the user is actually billed.
    private var priceBlock: some View {
        VStack(spacing: 3) {
            Text(plan.billingText ?? plan.priceText)
                .font(.sniglet(.title, weight: .bold))
                .foregroundStyle(DS.Color.ink)
            if let subtitle = priceSubtitle {
                Text(subtitle)
                    .font(.sniglet(.caption))
                    .foregroundStyle(DS.Color.charcoal)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Subordinate pricing line — trial length + the calculated per-month
    /// figure, both kept smaller than the billed amount above.
    private var priceSubtitle: String? {
        guard let days = plan.trialDays else { return nil }
        if plan.billingText != nil {
            // Annual: surface the calculated per-month figure, subordinate.
            return "\(days) days free, then only \(plan.priceText)"
        }
        return "\(days) days free"
    }

    /// Terms of Use (EULA) + Privacy Policy links, required in the purchase
    /// flow for auto-renewable subscriptions (Guideline 3.1.2(c)).
    private var legalLinks: some View {
        HStack(spacing: 6) {
            Link("Terms of Use", destination: LegalLinks.termsOfUse)
            Text("•")
            Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
        }
        .font(.sniglet(.caption))
        .foregroundStyle(.secondary)
        .tint(DS.Color.charcoal)
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
        if let best = fetched.first(where: { $0.isBestValue }) ?? fetched.first {
            plan = best
            planLoadFailed = false
        } else {
            // No live products — don't show placeholder prices as if real, and
            // don't offer a CTA that would buy nothing.
            planLoadFailed = true
        }
        isLoadingPlan = false
    }

    private func retryLoadPlan() async {
        isLoadingPlan = true
        await loadPlan()
    }

    private func subscribe() async {
        isWorking = true
        let result = await entitlements.purchase(plan)
        isWorking = false
        switch result {
        case .success:
            if let days = plan.trialDays {
                // Trial just started — remind everyone the day before it
                // converts (previously gated behind an opt-in toggle).
                await NotificationService.scheduleTrialEndingReminder(trialDays: days)
            }
            onSubscribed()
            dismiss()
        case .cancelled:
            break
        case .failed(let message):
            alert = PaywallAlert(title: "Purchase Failed", message: message)
        }
    }

    private func restore() async {
        isWorking = true
        let result = await entitlements.restore()
        isWorking = false
        switch result {
        case .restored:
            onSubscribed()
            dismiss()
        case .nothingToRestore:
            alert = PaywallAlert(
                title: "Nothing to Restore",
                message: "No previous purchases were found for this Apple Account.")
        case .failed(let message):
            alert = PaywallAlert(title: "Restore Failed", message: message)
        }
    }
}

#Preview {
    PaywallView()
}
