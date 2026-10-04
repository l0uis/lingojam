// Live entitlements backed by RevenueCat.
//
// Compiles only once the RevenueCat SPM package is present
// (`#if canImport(RevenueCat)`). wordrusApp wires this up behind the same
// guard. See REVENUECAT_SETUP.md.

#if canImport(RevenueCat)
import Foundation
import RevenueCat

/// RevenueCat configuration. The public SDK key is NOT a secret — it ships
/// inside every app binary.
///
/// This is the Apple **public app-specific key** (`appl_…`) for the Wordrus
/// App Store app — it drives real StoreKit purchases. (A `test_…` Test Store
/// key was used during early development.)
enum RevenueCatConfig {
    static let apiKey = "appl_XeOpXDxUoBdFpyQFiaIpTPYzhVi"
}

/// Bridges RevenueCat to the app's `EntitlementsProvider` abstraction so no
/// other file imports the SDK. Drives the paywall from the current Offering's
/// packages (live, localized prices) and keeps `isPro` correct across
/// renewals/expiries via the delegate.
final class RevenueCatEntitlementsProvider: NSObject, EntitlementsProvider, PurchasesDelegate {
    private var onChange: ((Bool) -> Void)?

    /// Packages from the most recent `availablePlans()` fetch, keyed by the
    /// PaywallPlan id (= store product identifier) so `purchase` can buy the
    /// exact RevenueCat package the user tapped.
    private var packagesByPlanID: [String: Package] = [:]

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        Purchases.shared.delegate = self
        Task {
            if let info = try? await Purchases.shared.customerInfo() {
                onChange(Self.isPro(info))
                Analytics.setIsPro(Self.isPro(info))
            }
        }
    }

    func availablePlans() async -> [PaywallPlan] {
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let offering = offerings.current else { return [] }
            var byID: [String: Package] = [:]
            var plans: [PaywallPlan] = []
            for pkg in offering.availablePackages {
                byID[pkg.storeProduct.productIdentifier] = pkg
                let eligible = await Self.isEligibleForIntroOffer(pkg.storeProduct)
                #if DEBUG
                await Self.logTrialDiagnostics(pkg.storeProduct, eligible: eligible)
                #endif
                plans.append(Self.plan(from: pkg, trialEligible: eligible))
            }
            packagesByPlanID = byID
            return plans
        } catch {
            return []
        }
    }

    /// Whether *this* Apple Account may still redeem the product's
    /// introductory free trial.
    ///
    /// This matters as much as whether the offer exists at all: a lapsed or
    /// returning subscriber is ineligible, so advertising "Start 7-day free
    /// trial" would put the paywall at odds with the App Store payment sheet,
    /// which charges the full price immediately — a Guideline 2.1(b)
    /// paywall/dialog discrepancy, and the exact failure mode that got earlier
    /// builds rejected.
    ///
    /// Anything other than a definite `.eligible` is treated as "no trial".
    /// `.unknown` (the check failed or timed out) errs toward silence: a truly
    /// eligible user then gets the trial anyway at checkout, which is a
    /// pleasant surprise rather than a rejection.
    private static func isEligibleForIntroOffer(_ product: StoreProduct) async -> Bool {
        guard product.introductoryDiscount?.paymentMode == .freeTrial else { return false }
        return await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product) == .eligible
    }

    #if DEBUG
    /// Explains, in the console, why a trial is or isn't being advertised.
    /// The two failure modes look identical on screen — App Store Connect
    /// hasn't propagated the introductory offer yet, versus the offer exists
    /// but this account can't redeem it — so print both facts side by side.
    private static func logTrialDiagnostics(_ product: StoreProduct, eligible: Bool) async {
        let offer = product.introductoryDiscount
        let status = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
        let report = """
        [trial] \(product.productIdentifier) price=\(product.localizedPriceString)
        [trial]   introductoryDiscount: \(offer.map { "\($0.subscriptionPeriod.value) \($0.subscriptionPeriod.unit) mode=\($0.paymentMode)" } ?? "nil — App Store Connect offer not visible to the app yet")
        [trial]   eligibility: \(status) → advertising trial: \(eligible)
        """
        print(report)
        // Also to disk: simulator stdout is unreliable to capture from the
        // command line, and this is the one diagnostic worth not losing.
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.write(to: dir.appendingPathComponent("trial-diagnostics.txt"),
                              atomically: true, encoding: .utf8)
        }
    }
    #endif

    func purchase(_ plan: PaywallPlan) async -> PurchaseResult {
        do {
            // Preferred path: buy the exact package the paywall displayed.
            if let pkg = packagesByPlanID[plan.id] {
                let result = try await Purchases.shared.purchase(package: pkg)
                if result.userCancelled { return .cancelled }
                return Self.isPro(result.customerInfo) ? .success
                    : .failed("The purchase didn't complete. Please try again.")
            }
            // Fallback: buy by raw product id (e.g. placeholder plans shown
            // before offerings loaded). An empty result means the product
            // isn't available in this environment — surface it rather than
            // letting the CTA silently do nothing.
            let products = await Purchases.shared.products([plan.id])
            guard let product = products.first else {
                return .failed("This subscription is temporarily unavailable. Please try again in a moment.")
            }
            let result = try await Purchases.shared.purchase(product: product)
            if result.userCancelled { return .cancelled }
            return Self.isPro(result.customerInfo) ? .success
                : .failed("The purchase didn't complete. Please try again.")
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    func restore() async -> RestoreResult {
        do {
            let info = try await Purchases.shared.restorePurchases()
            return Self.isPro(info) ? .restored : .nothingToRestore
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    // Live updates: renewals, expiries, family-sharing changes, etc.
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        onChange?(Self.isPro(customerInfo))
        Analytics.setIsPro(Self.isPro(customerInfo))
    }

    // MARK: - Mapping RevenueCat → PaywallPlan

    private static func isPro(_ info: CustomerInfo) -> Bool {
        // Prefer the named entitlement, but fall back to "any active
        // entitlement" — Wordrus ships a single Pro entitlement, so this is
        // correct and immune to an identifier mismatch between the app and the
        // RevenueCat dashboard (the original cause of purchases not unlocking).
        if info.entitlements[ProEntitlement.identifier]?.isActive == true { return true }
        return !info.entitlements.active.isEmpty
    }

    /// - Parameter trialEligible: whether this user can actually redeem the
    ///   product's free trial. When false the plan carries no trial, so the
    ///   paywall shows plain subscribe copy.
    private static func plan(from pkg: Package, trialEligible: Bool) -> PaywallPlan {
        let product = pkg.storeProduct
        // Trial comes ONLY from the store's real introductory offer, and only
        // when this account is still eligible for it — never fabricated.
        // Advertising a trial the App Store payment sheet won't honour is a
        // 2.1(b) rejection. nil here ⇒ the paywall shows no trial.
        return PaywallPlan(
            id: product.productIdentifier,
            title: title(for: pkg),
            priceText: priceText(for: pkg),
            trialDays: trialEligible ? trialDays(for: product) : nil,
            trialPeriodText: trialEligible ? trialPeriodText(for: product) : nil,
            billingText: billedSentence(for: pkg),
            isBestValue: false
        )
    }

    /// The billed-amount sentence under the CTA: the real charged price and
    /// how often it recurs, e.g. "Billed €22.99 yearly."
    private static func billedSentence(for pkg: Package) -> String {
        let price = pkg.storeProduct.localizedPriceString
        switch pkg.packageType {
        case .annual: return "Billed \(price) yearly."
        case .sixMonth: return "Billed \(price) every 6 months."
        case .threeMonth: return "Billed \(price) quarterly."
        case .twoMonth: return "Billed \(price) every 2 months."
        case .monthly: return "Billed \(price) monthly."
        case .weekly: return "Billed \(price) weekly."
        case .lifetime: return "\(price), one-time."
        default: return "Billed \(price)."
        }
    }

    private static func title(for pkg: Package) -> String {
        switch pkg.packageType {
        case .annual: return "Annual"
        case .sixMonth: return "6 Months"
        case .threeMonth: return "3 Months"
        case .twoMonth: return "2 Months"
        case .monthly: return "Monthly"
        case .weekly: return "Weekly"
        case .lifetime: return "Lifetime"
        default:
            let t = pkg.storeProduct.localizedTitle
            return t.isEmpty ? "Plan" : t
        }
    }

    private static func priceText(for pkg: Package) -> String {
        let price = pkg.storeProduct.localizedPriceString
        switch pkg.packageType {
        case .annual: return "\(price) / year"
        case .monthly: return "\(price) / month"
        case .weekly: return "\(price) / week"
        case .lifetime: return price
        default: return price
        }
    }

    /// The trial length phrased the way the store defines it — "1 week",
    /// "3 days", "1 month" — for user-facing copy. A one-week offer should
    /// read "1 week free", not "7 days free"; `trialDays` still does the date
    /// arithmetic. Returns nil when there's no free trial.
    ///
    /// Apple sometimes reports a one-week offer as 7 days rather than 1 week,
    /// so that case is normalised back to weeks.
    private static func trialPeriodText(for product: StoreProduct) -> String? {
        guard let intro = product.introductoryDiscount,
              intro.paymentMode == .freeTrial else { return nil }
        let period = intro.subscriptionPeriod
        var value = period.value
        var unit: String
        switch period.unit {
        case .day:
            if value % 7 == 0 && value >= 7 {
                value /= 7
                unit = "week"
            } else {
                unit = "day"
            }
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "day"
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    /// Length of a free-trial intro offer in days. Returns nil when there's
    /// no free trial.
    private static func trialDays(for product: StoreProduct) -> Int? {
        guard let intro = product.introductoryDiscount,
              intro.paymentMode == .freeTrial else { return nil }
        let period = intro.subscriptionPeriod
        switch period.unit {
        case .day: return period.value
        case .week: return period.value * 7
        case .month: return period.value * 30
        case .year: return period.value * 365
        @unknown default: return period.value
        }
    }
}
#endif
