import SwiftUI

/// The Pro paywall: a headline, the feature list and a sticky purchase
/// footer. Surfaced when a free user tries to *call* Dr Tusk (incoming
/// calls stay free).
///
/// Purchases route through `Entitlements`, which hides the store backend.
/// The single yearly plan + trial length come from the live RevenueCat
/// Offering (placeholder fallback); the DEBUG ⋯ menu unlocks for testing.
struct PaywallView: View {
    /// Invoked once the user becomes Pro (purchase, restore, or DEBUG
    /// simulate) — lets the presenter continue what the user was doing.
    var onSubscribed: () -> Void = {}
    /// What the user tapped to get here. Reported with `paywall_shown` / `paywall_dismissed`.
    var source: Analytics.PaywallSource = .unknown

    @Environment(\.dismiss) private var dismiss
    // One shown / dismissed pair per presentation; `onAppear` can run twice.
    @State private var analyticsShown = false
    @State private var analyticsOutcome: Analytics.PaywallOutcome = .closed
    @State private var shownAt = Date()
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
        let title: LocalizedStringResource
        let message: String
    }

    var body: some View {
        ZStack {
            DS.Color.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        header
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
        .onAppear {
            guard !analyticsShown else { return }
            analyticsShown = true
            shownAt = Date()
            Analytics.paywallShown(source)
        }
        .onDisappear {
            guard analyticsShown else { return }
            analyticsShown = false
            Analytics.paywallDismissed(source: source, outcome: analyticsOutcome, shownAt: shownAt)
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Header

    private var header: some View {
        Text("Unlock everything")
            .font(.gochiHand(size: 38, relativeTo: .largeTitle))
            .foregroundStyle(Color.whiteboardInk)
            .multilineTextAlignment(.center)
    }

    // MARK: - Icon tints

    /// One colour per icon circle so the rows don't read as a single block of
    /// ink. All dark enough to keep the white glyph legible.
    private enum IconTint {
        static let blue = DS.Color.ink
        static let coral = Color(red: 0.93, green: 0.33, blue: 0.38)
        static let orange = Color(red: 0.95, green: 0.55, blue: 0.15)
        static let purple = Color(red: 0.49, green: 0.33, blue: 0.82)
        static let teal = Color(red: 0.10, green: 0.58, blue: 0.68)
    }

    // MARK: - Benefits

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Everything in Pro")
                .font(.sniglet(.headline))
                .foregroundStyle(DS.Color.ink)
            benefitRow(icon: "phone.fill", tint: IconTint.blue, title: "Call Dr Tusk anytime",
                       detail: "He still calls you for free — Pro lets you call him on demand.")
            benefitRow(icon: "book.fill", tint: IconTint.orange, title: "Daily stories from Dr Tusk",
                       detail: "A short story every day, written with your words and read aloud by Dr Tusk.")
            benefitRow(icon: "text.badge.plus", tint: IconTint.coral, title: "Add your own words",
                       detail: "Look up any word you hear or see — definition and example added instantly.")
            // Only English speakers have more than one language to switch
            // between; promising it to anyone else would be a false benefit.
            if TargetLanguage.offered(to: NativeLanguage.current).count > 1 {
                benefitRow(icon: "globe", tint: IconTint.teal, title: "Every language",
                           detail: "Switch between all supported languages.")
            }
            benefitRow(icon: "square.grid.2x2.fill", tint: IconTint.purple, title: "Every topic",
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

    private func benefitRow(icon: String, tint: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.sniglet(.subheadline, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint))
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
                if plan.trialDays != nil { noPaymentDueNow }

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

                Text(priceSubtext)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.center)

                Text(appleBillingDisclosure)
                    .font(.sniglet(.caption2))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
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

    /// "Try 1 week free" when a trial applies, phrased in the store's own
    /// period unit rather than converted to days.
    private var ctaTitle: LocalizedStringResource {
        guard let period = plan.trialPeriodText else { return "Subscribe" }
        return "Try \(period) free"
    }

    /// Reassurance above the CTA, shown only when a trial actually applies —
    /// without one there *is* a payment due now, and saying otherwise would
    /// contradict the App Store payment sheet.
    private var noPaymentDueNow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("No payment due now")
        }
        .font(.sniglet(.subheadline, weight: .bold))
        .foregroundStyle(DS.Color.charcoal)
    }

    /// The pricing statement directly under the CTA: what the user is actually
    /// charged and how often. The trial is carried by the CTA and the "No
    /// payment due now" line above, so it isn't repeated here.
    ///
    /// This line is deliberately full-weight rather than fine print —
    /// Guideline 3.1.2(c) requires that introductory pricing not be more
    /// prominent than the price the user really pays, and this paywall has a
    /// rejection history on exactly that point.
    private var priceSubtext: LocalizedStringResource {
        let billed = plan.billingText ?? "\(plan.priceText)."
        return "\(billed) Cancel anytime."
    }

    /// Apple's standard auto-renewal disclosure, expected in the purchase flow
    /// for auto-renewable subscriptions.
    private let appleBillingDisclosure: LocalizedStringResource = "Payment is charged to your Apple ID account. Subscription auto-renews unless cancelled at least 24 hours before the end of the current period."

    /// Terms of Use (EULA) + Privacy Policy links, required in the purchase
    /// flow for auto-renewable subscriptions (Guideline 3.1.2(c)).
    private var legalLinks: some View {
        HStack(spacing: 4) {
            Link("Terms of Use", destination: LegalLinks.termsOfUse)
            Text("and")
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
                Label {
                    Text(verbatim: "Simulate Pro (Debug)")
                } icon: {
                    Image(systemName: "ladybug")
                }
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

    /// Stand-in yearly-plus-trial plan for visual QA of the trial layout:
    ///
    ///     xcrun simctl launch <udid> <bundle> -uiPreviewPaywall -uiPreviewTrial
    ///
    /// Needed because the trial copy and timeline only render when the *store*
    /// reports an introductory offer the account is eligible for, which can't
    /// be arranged on a plain simulator. Applies ONLY with the explicit
    /// `-uiPreviewTrial` flag — a plain `-uiPreviewPaywall` launch must keep
    /// showing whatever the store really returns (including the failure
    /// state), or the preview goes back to flattering us. DEBUG-only and gated
    /// on a launch argument, so it can never reach a user or App Review.
    private static var previewTrialPlan: PaywallPlan? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-uiPreviewTrial") else { return nil }
        return PaywallPlan(
            id: PaywallPlan.placeholderAnnual.id,
            title: PaywallPlan.placeholderAnnual.title,
            priceText: PaywallPlan.advertisedMonthlyPriceText,
            trialDays: 7,
            trialPeriodText: String(localized: "\(1) weeks"),
            billingText: PaywallPlan.placeholderAnnual.billingText,
            isBestValue: false
        )
        #else
        return nil
        #endif
    }

    /// Whether the DEBUG preview plan should replace a real one rather than
    /// merely stand in for a missing one.
    private static var forcesPreviewTrial: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiPreviewTrial")
        #else
        return false
        #endif
    }

    private func loadPlan() async {
        let fetched = await entitlements.availablePlans()
        if let preview = Self.previewTrialPlan, Self.forcesPreviewTrial {
            // DEBUG visual-QA launch only (see `previewTrialPlan`).
            plan = preview
            planLoadFailed = false
        } else if let best = fetched.first(where: { $0.isBestValue }) ?? fetched.first {
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
            analyticsOutcome = .purchased
            Analytics.capture(.purchaseCompleted)
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
            analyticsOutcome = .restored
            Analytics.capture(.purchaseRestored)
            dismiss()
        case .nothingToRestore:
            alert = PaywallAlert(
                title: "Nothing to Restore",
                message: String(localized: "No previous purchases were found for this Apple Account."))
        case .failed(let message):
            alert = PaywallAlert(title: "Restore Failed", message: message)
        }
    }
}

#Preview {
    PaywallView()
}
