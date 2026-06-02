import Foundation
import Observation

/// Names and storage keys for the single "Pro" entitlement. One source of
/// truth so the store backend, the cache, and any gating code agree.
enum ProEntitlement {
    /// Entitlement identifier as configured in the store backend (e.g. the
    /// RevenueCat entitlement identifier). Used by the real provider.
    static let identifier = "pro"

    /// Caches the last-known Pro status so gating is instant on launch
    /// (before any async store check finishes) and remains correct offline.
    static let cacheKey = "wordrus.entitlements.isPro"

    #if DEBUG
    /// DEBUG-only override so the paid flows can be exercised without a real
    /// purchase. Persisted so it survives relaunches while testing.
    static let debugSimulateKey = "wordrus.entitlements.debugSimulatePro"
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
    /// CTA copy and the trial-timeline dates.
    let trialDays: Int?
    /// Real billing line (e.g. "€23.99/year"), rendered bold.
    let billingText: String?
    let isBestValue: Bool

    /// Free-trial phrase derived from `trialDays`, e.g. "3-day free trial".
    /// nil → no trial (CTA reads "Subscribe").
    var trialText: String? { trialDays.map { "\($0)-day free trial" } }

    /// Advertised per-month framing for the yearly plan. The REAL charged
    /// price (€23.99/year) + 3-day trial come from the store; this is the
    /// marketing headline the product owner chose ("just €1.99/mo, billed
    /// yearly"). NOTE: hardcoded in €, so it won't auto-localize to other
    /// currencies — revisit if non-Euro storefronts are targeted.
    static let advertisedMonthlyPriceText = "€1.99 / mo"

    static let placeholderAnnual = PaywallPlan(
        id: "wordrus_pro_annual",
        title: "Yearly",
        priceText: advertisedMonthlyPriceText,
        trialDays: 3,
        billingText: "€23.99/year",
        isBestValue: false
    )

    /// Plans rendered before a real store backend supplies live products.
    /// Single yearly plan (the only plan offered).
    static let placeholders = [placeholderAnnual]
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

    /// Run the purchase flow for `plan`. Returns whether the user ends up
    /// entitled. A user cancellation is **not** an error — return `false`.
    func purchase(_ plan: PaywallPlan) async throws -> Bool

    /// Restore prior purchases. Returns whether Pro was restored.
    func restore() async throws -> Bool
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
    func purchase(_ plan: PaywallPlan) async throws -> Bool { false }
    func restore() async throws -> Bool { false }
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
        #if DEBUG
        let simulated = UserDefaults.standard.bool(forKey: ProEntitlement.debugSimulateKey)
        self.isPro = cached || simulated
        #else
        self.isPro = cached
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

    /// Purchase `plan`. Returns whether the user is now entitled.
    func purchase(_ plan: PaywallPlan) async -> Bool {
        do {
            let entitled = try await provider.purchase(plan)
            if entitled { apply(storeIsPro: true) }
            return entitled
        } catch {
            return false
        }
    }

    /// Restore prior purchases. Returns whether Pro was restored.
    func restore() async -> Bool {
        do {
            let restored = try await provider.restore()
            if restored { apply(storeIsPro: true) }
            return restored
        } catch {
            return false
        }
    }

    /// Fold a fresh store reading into `isPro`, cache it, and keep the DEBUG
    /// simulate override layered on top.
    private func apply(storeIsPro: Bool) {
        UserDefaults.standard.set(storeIsPro, forKey: ProEntitlement.cacheKey)
        #if DEBUG
        let simulated = UserDefaults.standard.bool(forKey: ProEntitlement.debugSimulateKey)
        isPro = storeIsPro || simulated
        #else
        isPro = storeIsPro
        #endif
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
        let storeIsPro = UserDefaults.standard.bool(forKey: ProEntitlement.cacheKey)
        isPro = storeIsPro || on
    }
    #endif
}
