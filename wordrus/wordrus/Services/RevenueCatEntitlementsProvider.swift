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

    private static func plan(from pkg: Package) -> PaywallPlan {
        let product = pkg.storeProduct
        // Yearly plan uses the advertised "€1.99/mo, billed yearly" framing:
        // the real yearly price + trial come from the store, shown in the
        // detail line; the headline is the marketing per-month figure.
        if pkg.packageType == .annual {
            // Trial comes ONLY from the store's real introductory offer — never
            // fabricated. Advertising a trial the App Store payment sheet won't
            // honour is a 2.1(b) rejection (paywall/dialog discrepancy). nil
            // here ⇒ the paywall shows no trial.
            return PaywallPlan(
                id: product.productIdentifier,
                title: "Yearly",
                priceText: PaywallPlan.advertisedMonthlyPriceText,
                trialDays: trialDays(for: product),
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
