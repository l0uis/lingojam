// Live entitlements backed by RevenueCat.
//
// This whole file compiles to NOTHING until the RevenueCat SPM package is
// added to the project (`#if canImport(RevenueCat)`), so the app builds and
// runs on the free provider today. Once you add the package + API key (see
// REVENUECAT_SETUP.md), it activates automatically — wordrusApp already
// wires it up behind the same `canImport` guard.

#if canImport(RevenueCat)
import Foundation
import RevenueCat

/// RevenueCat configuration. The public SDK key is NOT a secret — it ships
/// inside every app binary — so a literal here is fine. Replace the
/// placeholder with the key from the RevenueCat dashboard (Project → API
/// keys → Public app-specific key for Apple).
enum RevenueCatConfig {
    static let apiKey = "appl_REPLACE_WITH_YOUR_PUBLIC_SDK_KEY"
}

/// Bridges RevenueCat to the app's `EntitlementsProvider` abstraction so no
/// other file imports the SDK. Pushes renewals/expiries live via the
/// delegate, so `Entitlements.isPro` stays correct without polling.
final class RevenueCatEntitlementsProvider: NSObject, EntitlementsProvider, PurchasesDelegate {
    private var onChange: ((Bool) -> Void)?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        Purchases.shared.delegate = self
        Task {
            if let info = try? await Purchases.shared.customerInfo() {
                onChange(Self.isPro(info))
            }
        }
    }

    func purchase(_ plan: PaywallPlan) async throws -> Bool {
        // `plan.id` is the store product identifier. With RevenueCat
        // Offerings you may prefer fetching packages from the current
        // offering instead; this product-id path keeps the abstraction flat.
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

    private static func isPro(_ info: CustomerInfo) -> Bool {
        info.entitlements[ProEntitlement.identifier]?.isActive == true
    }
}
#endif
