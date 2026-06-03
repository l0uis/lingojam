# RevenueCat setup — going live with the Pro paywall

The paywall, entitlement logic, and the outgoing-call gate are **already built
and working** on a free provider. The app compiles and runs today; free users
see the paywall when they tap **Call Dr Tusk**, and you can exercise the Pro
flows with the DEBUG **Simulate Pro** button on the paywall.

This doc covers the last mile: connecting real purchases via RevenueCat.

## The model (what's gated)

> **Dr Tusk calls you for free; calling Dr Tusk is Pro.**

- **Incoming calls stay free** — notification taps and the 10-card engagement
  trigger (`EngagementTracker`) are untouched.
- **Outgoing calls are Pro** — the single seam is the "Call Dr Tusk" button in
  `PhoneView` → `callDrTusk()`, which checks `Entitlements.shared.isPro`.
- Content-breadth gating (all languages / levels / decks) is pitched on the
  paywall but **not yet enforced in code** — that's the next phase, pending the
  level-gate decision (A1–A2 free vs. progress-freely-but-gate-jumping).

## Architecture (already in place)

| File | Role |
|------|------|
| `Services/Entitlements.swift` | `@Observable` store exposing `isPro`; `EntitlementsProvider` protocol; `FreeEntitlementsProvider`; `PaywallPlan`. No SDK import. |
| `Views/PaywallView.swift` | The paywall UI. Purchases route through `Entitlements`. |
| `Views/PhoneView.swift` | `callDrTusk()` — the gate. |
| `Services/RevenueCatEntitlementsProvider.swift` | Live provider, compiled only `#if canImport(RevenueCat)`. |
| `wordrusApp.swift` | Configures + bootstraps RevenueCat behind the same `canImport` guard. |

Nothing outside `RevenueCatEntitlementsProvider.swift` and the guarded blocks
in `wordrusApp.swift` touches the SDK.

## Steps to go live

1. **Add the SPM package** ✅ DONE — RevenueCat `5.75.0` is added to the
   `wordrus` target (via `purchases-ios`, pinned in `Package.resolved`,
   up-to-next-major from 5.0.0). `#if canImport(RevenueCat)` is now active and
   the project builds against the live SDK.

2. **Set your API key** in `Services/RevenueCatEntitlementsProvider.swift`:
   - RevenueCat dashboard → Project → API keys → **Public app-specific key for
     Apple** (starts with `appl_`).
   - Replace `RevenueCatConfig.apiKey`. (This key is not a secret — it ships in
     the binary.)

3. **Configure products in App Store Connect**, then import them into
   RevenueCat:
   - One auto-renewing subscription in a "Wordrus Pro" group:
     - **`wordrus_pro_yearly`** — 1 year, €23.99, **Free 3-day** intro offer.
       (NOTE: `wordrus_pro_annual` is permanently burned — it was created
       under the old `com.louiscurrie.lingojam` app record and Apple product
       IDs can't be reused, so the live product is `wordrus_pro_yearly`.)
   - This ID must match `PaywallPlan.placeholderAnnual.id` in
     `Entitlements.swift` (the offline fallback; the live purchase keys off the
     RevenueCat package, so any ID works as long as the offering serves it).

4. **Create the entitlement** in RevenueCat:
   - Entitlement identifier: **`pro`** (matches `ProEntitlement.identifier`).
   - Attach both products to it.

5. **(Optional) Live products instead of placeholders.** `PaywallView`
   currently renders `PaywallPlan.placeholders` with hardcoded price text. To
   show real localized prices, fetch the current Offering and map its packages
   to `PaywallPlan`s (display `storeProduct.localizedPriceString`). The purchase
   path already keys off `plan.id`.

6. **Test** with a StoreKit sandbox account, then verify `Restore purchases`.

## Notes

- `isPro` is cached in `UserDefaults` so gating is instant at launch and correct
  offline; the provider's delegate keeps it live across renewals/expiries.
- The DEBUG **Simulate Pro** button stays available in debug builds even after
  RevenueCat is live — handy for testing gated UI without burning sandbox
  purchases. It's stripped from release builds.
- To gate content breadth later, read `Entitlements.shared.isPro` at the
  language picker, CEFR level picker, and deck picker — same pattern as the
  call gate.
