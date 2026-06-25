import SwiftUI

struct SettingsView: View {
    let onRestartOnboarding: () -> Void

    @AppStorage(OnboardingDefaultsKey.displayName) private var displayName: String = ""
    @AppStorage(OnboardingDefaultsKey.notificationsEnabled) private var notificationsEnabled: Bool = false
    @AppStorage(OnboardingDefaultsKey.notificationsPerDay) private var notificationsPerDay: Int = 10
    @AppStorage(DailySetConfig.defaultsKey) private var dailySetSize: Int = DailySetConfig.defaultSize

    @State private var isEditingReminder: Bool = false
    @State private var isShowingWidgetSheet: Bool = false
    @State private var isShowingPaywall: Bool = false
    @State private var entitlements = Entitlements.shared
    @State private var restoreMessage: String?

    var body: some View {
        Form {
            // A visible, always-reachable entry to the subscription. Without
            // this the paywall is only surfaced by in-context Pro gates (e.g.
            // calling Dr Tusk), which App Review couldn't locate.
            Section {
                if entitlements.isPro {
                    LabeledContent {
                        Text("Active")
                            .font(.sniglet(.body))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Wordrus Pro", systemImage: "key.fill")
                            .font(.sniglet(.body))
                            .foregroundStyle(.primary)
                    }
                } else {
                    HStack {
                        Label("Upgrade to Wordrus Pro", systemImage: "key.fill")
                            .font(.sniglet(.body))
                            .foregroundStyle(DS.Color.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.sniglet(.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingPaywall = true }
                }

                Button {
                    Task { await restorePurchases() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }
            } header: {
                sectionHeader("Wordrus Pro")
            }

            if !displayName.isEmpty {
                Section {
                    LabeledContent {
                        Text(displayName).font(.sniglet(.body))
                    } label: {
                        Text("Name").font(.sniglet(.body))
                    }
                } header: {
                    sectionHeader("You")
                }
            }

            Section {
                Stepper(
                    value: $dailySetSize,
                    in: DailySetConfig.minSize...DailySetConfig.maxSize
                ) {
                    HStack {
                        Text("Words per day")
                            .font(.sniglet(.body))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(dailySetSize)")
                            .font(.sniglet(.body))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Reminders")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(notificationsEnabled ? "\(notificationsPerDay) / day" : "Off")
                        .font(.sniglet(.body))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.sniglet(.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isEditingReminder = true
                }

                HStack {
                    Text("Widget")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.sniglet(.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isShowingWidgetSheet = true
                }
            } header: {
                sectionHeader("Learning")
            }

            #if DEBUG
            Section {
                Toggle(isOn: debugSimulateProBinding) {
                    Label("Pro features unlocked", systemImage: "crown.fill")
                        .font(.sniglet(.body))
                }
                .tint(DS.Color.ink)
                .disabled(entitlements.isForcingFree)

                Toggle(isOn: debugForceFreeBinding) {
                    Label("Force free (ignore real purchase)", systemImage: "lock.fill")
                        .font(.sniglet(.body))
                }
                .tint(DS.Color.ink)

                Button(role: .destructive) {
                    onRestartOnboarding()
                } label: {
                    Label("Restart onboarding", systemImage: "arrow.counterclockwise")
                        .font(.sniglet(.body))
                }
            } header: {
                sectionHeader("Debug")
            } footer: {
                Text("Flip Pro on to walk through paid flows without buying. Force free overrides a real sandbox purchase so you can test the free/paywall experience. Restarting onboarding resets all answers. Debug builds only.")
                    .font(.sniglet(.footnote))
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .listRowSeparator(.hidden)
        .background(DS.Color.paper.ignoresSafeArea())
        .gochiHandNavigationTitle("Settings")
        .sheet(isPresented: $isEditingReminder) {
            EditReminderSheet()
        }
        .sheet(isPresented: $isShowingWidgetSheet) {
            InstallWidgetSheet()
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView()
        }
        .alert("Restore Purchases",
               isPresented: Binding(get: { restoreMessage != nil },
                                    set: { if !$0 { restoreMessage = nil } }),
               presenting: restoreMessage) { _ in
            Button("OK", role: .cancel) { restoreMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func restorePurchases() async {
        switch await Entitlements.shared.restore() {
        case .restored:
            restoreMessage = "Your Pro membership has been restored."
        case .nothingToRestore:
            restoreMessage = "No previous purchases were found for this Apple Account."
        case .failed(let message):
            restoreMessage = message
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).sectionHeaderStyle()
    }

    #if DEBUG
    /// Bridges the DEBUG-only Pro override to a SwiftUI `Toggle`. Writes go
    /// through `Entitlements.setSimulatedPro` so `isPro` recomputes in place
    /// and any gated view in the app reacts instantly.
    private var debugSimulateProBinding: Binding<Bool> {
        Binding(
            get: { Entitlements.shared.isSimulatingPro },
            set: { Entitlements.shared.setSimulatedPro($0) }
        )
    }

    /// Bridges the DEBUG-only force-free override to a SwiftUI `Toggle`. When
    /// on, the app behaves as free even if the store reports an active Pro
    /// entitlement, so the free/paywall flows are testable on a sandbox
    /// account that already owns Pro.
    private var debugForceFreeBinding: Binding<Bool> {
        Binding(
            get: { Entitlements.shared.isForcingFree },
            set: { Entitlements.shared.setForceFree($0) }
        )
    }
    #endif
}

#Preview {
    NavigationStack {
        SettingsView(onRestartOnboarding: {})
    }
}
