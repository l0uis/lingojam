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
            }
        }
    }

    func availablePlans() async -> [PaywallPlan] {
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let offering = offerings.current else { return [] }
            var byID: [String: Package] = [:]
            let plans = offering.availablePackages.map { pkg -> PaywallPlan in
                byID[pkg.storeProduct.productIdentifier] = pkg
                return Self.plan(from: pkg)
            }
            packagesByPlanID = byID
            return plans
        } catch {
            return []
        }
    }

    func purchase(_ plan: PaywallPlan) async throws -> Bool {
        // Preferred path: buy the exact package the paywall displayed.
        if let pkg = packagesByPlanID[plan.id] {
            let result = try await Purchases.shared.purchase(package: pkg)
            if result.userCancelled { return false }
            return Self.isPro(result.customerInfo)
        }
        // Fallback: buy by raw product id (e.g. placeholder plans shown before
        // offerings loaded).
        let products = await Purchases.shared.products([plan.id])
        guard let product = products.first else { return false }
        let result = try await Purchases.shared.purchase(product: product)
        if result.userCancelled { return false }
        return Self.isPro(result.customerInfo)
    }

    func restore() async throws -> Bool {
        let info = try await Purchases.shared.restorePurchases()
        return Self.isPro(info)
    }

    // Live updates: renewals, expiries, family-sharing changes, etc.
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        onChange?(Self.isPro(customerInfo))
    }

    // MARK: - Mapping RevenueCat → PaywallPlan

    private static func isPro(_ info: CustomerInfo) -> Bool {
        info.entitlements[ProEntitlement.identifier]?.isActive == true
    }

    private static func plan(from pkg: Package) -> PaywallPlan {
        let product = pkg.storeProduct
        // Yearly plan uses the advertised "€1.99/mo, billed yearly" framing:
        // the real yearly price + trial come from the store, shown in the
        // detail line; the headline is the marketing per-month figure.
        if pkg.packageType == .annual {
            // Trial from the store when present; otherwise fall back to the
            // designed 3-day trial — the Test Store doesn't simulate intro
            // offers, and the real trial is configured in App Store Connect
            // for production.
            // Trial from the store when present; otherwise fall back to the
            // designed 3-day trial — the Test Store doesn't simulate intro
            // offers, and the real trial is configured in App Store Connect
            // for production.
            let days = trialDays(for: product) ?? 3
            return PaywallPlan(
                id: product.productIdentifier,
                title: "Yearly",
                priceText: PaywallPlan.advertisedMonthlyPriceText,
                trialDays: days,
                billingText: "\(product.localizedPriceString)/year",
                isBestValue: false
            )
        }
        return PaywallPlan(
            id: product.productIdentifier,
            title: title(for: pkg),
            priceText: priceText(for: pkg),
            trialDays: trialDays(for: product),
            billingText: nil,
            isBestValue: false
        )
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
