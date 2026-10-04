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

3. **Configure products in App Store Connect** ✅ DONE, then import them into
   RevenueCat:
   - One auto-renewing subscription in a "Wordrus Pro" group:
     - **`wordrus_pro_year`** — 1 year, €22.99.
       (NOTE: `wordrus_pro_annual` and `wordrus_pro_yearly` are both permanently
       burned — Apple product IDs can't be reused once created/deleted — so the
       live product ID is `wordrus_pro_year`.)
   - This ID must match `PaywallPlan.placeholderAnnual.id` in
     `Entitlements.swift` (the offline fallback; the live purchase keys off the
     RevenueCat package, so any ID works as long as the offering serves it).

4. **Create the entitlement** in RevenueCat ✅ DONE:
   - Entitlement identifier: **`Wordrus Pro`** (matches
     `ProEntitlement.identifier` — case- and space-sensitive).
   - Attach the product to it.

5. **Live products instead of placeholders** ✅ DONE — `availablePlans()` maps
   the current Offering's packages to `PaywallPlan`s with real localized
   prices. If no live plan loads, the paywall shows a Retry rather than
   placeholder prices it can't actually charge.

6. **Test** with a StoreKit sandbox account on a real device (plain simulators
   can't buy real App Store products), then verify `Restore purchases`.

## Adding the 7-day free trial

The app renders the trial entirely from what the store reports — there is no
trial length in code. Turning it on is App Store Connect work:

1. ASC → the `wordrus_pro_year` subscription → **Introductory Offers** → create
   one for **All Countries or Regions**, type **Free**, duration **1 week**, no
   end date.
2. Wait for it to leave "Missing Metadata"/pending, then let RevenueCat refresh
   (it re-reads the product; force it by re-fetching offerings in the app).
3. Nothing to deploy — an installed build picks the trial up on its next
   offerings fetch. The CTA becomes "Try 1 week free", and the "No payment due
   now" line and trial timeline card appear. With no trial the CTA reads
   "Subscribe"; the billed line is the same either way.

Trial copy is phrased in the store's own period unit (`trialPeriodText`), so a
one-week offer reads "1 week", not "7 days". `trialDays` still drives the
timeline dates and the trial-ending reminder.

Footer order: "No payment due now" (trial only) → CTA → billed line → Apple's
auto-renewal disclosure → "Terms of Use and Privacy Policy". The billed line
comes from `billedSentence(for:)` and always names the real charged amount and
cadence ("Billed €22.99 yearly."), at full weight rather than as fine print —
Guideline 3.1.2(c) requires that introductory pricing not out-shout the price
the user actually pays, and this paywall has a rejection history on that point.

### Checking whether the offer has reached the app

DEBUG builds write the answer to
`<app container>/Documents/trial-diagnostics.txt` on every plan fetch:

```
xcrun simctl launch <udid> com.louiscurrie.wordrus -uiPreviewPaywall
cat "$(xcrun simctl get_app_container <udid> com.louiscurrie.wordrus data)/Documents/trial-diagnostics.txt"
```

It reports the product's `introductoryDiscount` and the eligibility status
separately, which distinguishes the two identical-looking failures: the ASC
offer hasn't propagated (`introductoryDiscount: nil`,
`noIntroOfferExists`) versus the offer exists but this account can't redeem it
(`ineligible`).

**Note the simulator's storefront.** A US-storefront simulator reports
`$24.99`, not `€22.99` — the euro figure in `PaywallPlan.placeholderAnnual` is
only a fallback and does not reflect what a given device will be charged.

**The trial is shown only to accounts that can actually redeem it.**
`availablePlans()` calls `checkTrialOrIntroDiscountEligibility` per product and
drops the trial for anyone ineligible (a lapsed or returning subscriber). This
is deliberate: advertising a trial the App Store payment sheet won't honour is
the Guideline 2.1(b) paywall/dialog discrepancy that got earlier builds
rejected. An indeterminate `.unknown` result is treated as "no trial" — an
eligible user then gets it free at checkout anyway, which is a pleasant
surprise rather than a rejection.

To preview the trial layout without a store (screenshots, visual QA):

```
xcrun simctl launch <udid> com.louiscurrie.wordrus -uiPreviewPaywall -uiPreviewTrial
```

DEBUG-only and gated on the launch argument, so it can't reach users or App
Review. Omit `-uiPreviewTrial` to preview whatever the store really offers.

## Notes

- `isPro` is cached in `UserDefaults` so gating is instant at launch and correct
  offline; the provider's delegate keeps it live across renewals/expiries.
- The DEBUG **Simulate Pro** button stays available in debug builds even after
  RevenueCat is live — handy for testing gated UI without burning sandbox
  purchases. It's stripped from release builds.
- To gate content breadth later, read `Entitlements.shared.isPro` at the
  language picker, CEFR level picker, and deck picker — same pattern as the
  call gate.
