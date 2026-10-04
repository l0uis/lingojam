import Foundation
import Observation

/// Names and storage keys for the single "Pro" entitlement. One source of
/// truth so the store backend, the cache, and any gating code agree.
enum ProEntitlement {
    /// Entitlement identifier as configured in the store backend — must match
    /// the RevenueCat entitlement identifier EXACTLY (it's case- and
    /// space-sensitive). The provider also treats *any* active entitlement as
    /// Pro (Wordrus has a single entitlement), so an identifier mismatch can't
    /// silently break unlocking again.
    static let identifier = "Wordrus Pro"

    /// Caches the last-known Pro status so gating is instant on launch
    /// (before any async store check finishes) and remains correct offline.
    static let cacheKey = "wordrus.entitlements.isPro"

    #if DEBUG
    /// DEBUG-only override so the paid flows can be exercised without a real
    /// purchase. Persisted so it survives relaunches while testing.
    static let debugSimulateKey = "wordrus.entitlements.debugSimulatePro"

    /// DEBUG-only override to force the FREE experience even when a real store
    /// entitlement is active. Needed because the test/sandbox Apple account may
    /// already own Pro (so the store reports `isPro == true`), which otherwise
    /// makes it impossible to exercise the free/paywall flows. Wins over both
    /// the real entitlement and `debugSimulateKey`.
    static let debugForceFreeKey = "wordrus.entitlements.debugForceFree"
    #endif
}

/// A purchasable plan shown on the paywall. `id` maps to a store product
/// (RevenueCat package / StoreKit product identifier). Until a real store
/// backend is wired in, the `placeholder*` values render the UI with
/// representative copy.
struct PaywallPlan: Identifiable, Hashable {
    let id: String
    let title: String
    let priceText: String
    /// Length of the free trial in days, when the plan has one. Drives the
    /// trial-timeline dates and the trial-ending reminder.
    let trialDays: Int?
    /// The trial length as the store expresses it — "1 week", "3 days" — used
    /// for user-facing copy so a one-week offer reads "1 week free" rather
    /// than "7 days free". nil when the plan has no trial.
    var trialPeriodText: String?
    /// The billed-amount sentence shown under the CTA, e.g.
    /// "Billed €22.99 yearly." — the real charged price and its cadence, built
    /// from the store product so it stays localized.
    let billingText: String?
    let isBestValue: Bool

    /// Free-trial phrase for the CTA, e.g. "1 week free".
    /// nil → no trial (CTA reads "Subscribe").
    var trialText: String? { trialPeriodText.map { "\($0) free" } }

    /// Advertised per-month framing for the yearly plan. The REAL charged
    /// price (€23.99/year) + 3-day trial come from the store; this is the
    /// marketing headline the product owner chose ("just €1.99/mo, billed
    /// yearly"). NOTE: hardcoded in €, so it won't auto-localize to other
    /// currencies — revisit if non-Euro storefronts are targeted.
    static let advertisedMonthlyPriceText = "€1.99 / mo"

    static let placeholderAnnual = PaywallPlan(
        id: "wordrus_pro_year",
        title: "Yearly",
        priceText: advertisedMonthlyPriceText,
        trialDays: nil,
        trialPeriodText: nil,
        billingText: "Billed €22.99 yearly.",
        isBestValue: false
    )

    /// Plans rendered before a real store backend supplies live products.
    /// Single yearly plan (the only plan offered).
    static let placeholders = [placeholderAnnual]
}

/// Outcome of a purchase attempt. Distinguishes a user backing out (no UI)
/// from a genuine failure (show the message) so the paywall never leaves a
/// tapped CTA silently doing nothing — a common App Review rejection.
enum PurchaseResult {
    /// Purchase completed and the user is now Pro.
    case success
    /// User dismissed the purchase sheet. Not an error — show nothing.
    case cancelled
    /// Something went wrong; `message` is user-facing.
    case failed(String)
}

/// Outcome of a restore attempt, with the same show-feedback rationale.
enum RestoreResult {
    /// A prior purchase was found and Pro restored.
    case restored
    /// The restore succeeded but found nothing to restore.
    case nothingToRestore
    /// Something went wrong; `message` is user-facing.
    case failed(String)
}

/// Abstraction over whatever actually grants entitlements (RevenueCat, a
/// mock, StoreKit). Keeps `Entitlements` and every gating call site free of
/// any SDK dependency — to go live, swap the provider in exactly one place.
@MainActor
protocol EntitlementsProvider: AnyObject {
    /// Begin observing entitlement changes. `onChange` is invoked with the
    /// current Pro status on start and again whenever it changes (purchase,
    /// restore, renewal, expiry).
    func start(onChange: @escaping (Bool) -> Void)

    /// The purchasable plans to show on the paywall. Real providers fetch
    /// these live (e.g. from a RevenueCat Offering) so prices are accurate
    /// and localized. May return an empty array if none are available.
    func availablePlans() async -> [PaywallPlan]

    /// Run the purchase flow for `plan`. The provider maps its own errors to
    /// `.failed` so callers always get a user-facing outcome.
    func purchase(_ plan: PaywallPlan) async -> PurchaseResult

    /// Restore prior purchases.
    func restore() async -> RestoreResult
}

/// Default provider used until a real store backend is wired in. Grants
/// nothing and treats purchases/restores as no-ops, so the whole paywall +
/// gating layer can ship and be exercised today via the DEBUG simulate
/// toggle. Replaced by `RevenueCatEntitlementsProvider` once the SDK and an
/// API key are present (see REVENUECAT_SETUP.md).
@MainActor
final class FreeEntitlementsProvider: EntitlementsProvider {
    func start(onChange: @escaping (Bool) -> Void) { onChange(false) }
    func availablePlans() async -> [PaywallPlan] { PaywallPlan.placeholders }
    func purchase(_ plan: PaywallPlan) async -> PurchaseResult { .cancelled }
    func restore() async -> RestoreResult { .nothingToRestore }
}

/// App-wide entitlement state. Observe `isPro` from any view to gate Pro
/// features. The actual grant logic lives behind an `EntitlementsProvider`
/// so this type — and all gating code — never imports a payments SDK.
///
/// Core paywall rule for wordrus: **Dr Tusk calls you for free; calling
/// Dr Tusk is Pro.** The outgoing-call seam checks `isPro`.
@MainActor
@Observable
final class Entitlements {
    /// Shared instance. Defaults to the free provider; `bootstrap(provider:)`
    /// swaps in the real one at launch once the SDK is present.
    static let shared = Entitlements(provider: FreeEntitlementsProvider())

    private var provider: EntitlementsProvider

    /// Whether the user currently has the Pro entitlement. Seeded from cache
    /// for instant, offline-correct gating, then kept live by the provider.
    private(set) var isPro: Bool

    init(provider: EntitlementsProvider) {
        self.provider = provider
        let cached = UserDefaults.standard.bool(forKey: ProEntitlement.cacheKey)
        self.isPro = Self.effectiveIsPro(storeIsPro: cached)
    }

    /// Fold a raw store reading together with the DEBUG simulate toggle into
    /// the effective Pro status. Single source of truth so `init`, `apply`,
    /// and the DEBUG toggle agree.
    ///
    /// NOTE: we deliberately do NOT auto-grant Pro on sandbox-receipt builds.
    /// The sandbox receipt is present for BOTH TestFlight *and* App Review
    /// builds — they're indistinguishable at runtime — so auto-granting would
    /// unlock everything for the App Review reviewer and leave them unable to
    /// reach or test the purchase flow (a guaranteed Guideline 2.1 follow-up).
    /// TestFlight testers exercise the real (free) StoreKit sandbox purchase
    /// instead, which is exactly what reviewers do too.
    private static func effectiveIsPro(storeIsPro: Bool) -> Bool {
        #if DEBUG
        // Force-free wins over everything so the free/paywall flows can be
        // tested even when the sandbox account already owns Pro.
        if UserDefaults.standard.bool(forKey: ProEntitlement.debugForceFreeKey) { return false }
        let simulated = UserDefaults.standard.bool(forKey: ProEntitlement.debugSimulateKey)
        return storeIsPro || simulated
        #else
        return storeIsPro
        #endif
    }

    /// Replace the provider (e.g. with RevenueCat) and start observing.
    /// Call once at app launch, before any gated UI appears.
    func bootstrap(provider: EntitlementsProvider) {
        self.provider = provider
        start()
    }

    /// Start observing the current provider. Safe to call once at launch.
    func start() {
        provider.start { [weak self] storeIsPro in
            Task { @MainActor in self?.apply(storeIsPro: storeIsPro) }
        }
    }

    /// The plans to show on the paywall, fetched from the active provider.
    func availablePlans() async -> [PaywallPlan] {
        await provider.availablePlans()
    }

    /// Purchase `plan`, applying the entitlement on success.
    func purchase(_ plan: PaywallPlan) async -> PurchaseResult {
        let result = await provider.purchase(plan)
        if case .success = result { apply(storeIsPro: true) }
        return result
    }

    /// Restore prior purchases, applying the entitlement on success.
    func restore() async -> RestoreResult {
        let result = await provider.restore()
        if case .restored = result { apply(storeIsPro: true) }
        return result
    }

    /// Fold a fresh store reading into `isPro`, cache it, and keep the DEBUG
    /// simulate override layered on top.
    private func apply(storeIsPro: Bool) {
        UserDefaults.standard.set(storeIsPro, forKey: ProEntitlement.cacheKey)
        isPro = Self.effectiveIsPro(storeIsPro: storeIsPro)
    }

    #if DEBUG
    /// Whether the DEBUG Pro override is currently on.
    var isSimulatingPro: Bool {
        UserDefaults.standard.bool(forKey: ProEntitlement.debugSimulateKey)
    }

    /// Toggle the DEBUG-only Pro override (no real purchase). Lets us walk
    /// the paid flows in the simulator / on-device debug builds.
    func setSimulatedPro(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ProEntitlement.debugSimulateKey)
        recomputeFromStore()
    }

    /// Whether the DEBUG force-free override is currently on.
    var isForcingFree: Bool {
        UserDefaults.standard.bool(forKey: ProEntitlement.debugForceFreeKey)
    }

    /// Toggle the DEBUG-only force-free override, which downgrades the app to
    /// the free experience even when a real store entitlement is active.
    func setForceFree(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ProEntitlement.debugForceFreeKey)
        recomputeFromStore()
    }

    /// Recompute `isPro` in place from the cached store reading + DEBUG
    /// overrides so any gated view reacts instantly.
    private func recomputeFromStore() {
        let storeIsPro = UserDefaults.standard.bool(forKey: ProEntitlement.cacheKey)
        isPro = Self.effectiveIsPro(storeIsPro: storeIsPro)
    }
    #endif
}
