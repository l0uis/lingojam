import SwiftUI

struct SettingsView: View {
    let onRestartOnboarding: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context

    @AppStorage(OnboardingDefaultsKey.displayName) private var displayName: String = ""
    @AppStorage(OnboardingDefaultsKey.notificationsEnabled) private var notificationsEnabled: Bool = false
    @AppStorage(OnboardingDefaultsKey.notificationsPerDay) private var notificationsPerDay: Int = 10
    @AppStorage(DailySetConfig.defaultsKey) private var dailySetSize: Int = DailySetConfig.defaultSize
    @AppStorage(OnboardingDefaultsKey.cefrLevel) private var cefrLevelRaw: String = CEFRLevel.a1.rawValue
    @AppStorage(OnboardingDefaultsKey.liveActivityEnabled) private var liveActivityEnabled: Bool = false

    @State private var analyticsEnabled = Analytics.isEnabled
    @State private var isEditingReminder: Bool = false
    @State private var isShowingWidgetSheet: Bool = false
    @State private var isShowingPaywall: Bool = false
    @State private var entitlements = Entitlements.shared
    @State private var restoreMessage: String?
    @State private var nativeLanguage = NativeLanguage.current
    /// A native-language change that rules out the current target, held
    /// until the learner confirms the target switch it implies.
    @State private var pendingNativeLanguage: NativeLanguage?

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
                            .foregroundStyle(DS.Color.ink)
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
                // Hidden until a second native language has something to learn
                // (i.e. until the English seed ships).
                if NativeLanguage.selectable.count > 1 {
                    Picker(selection: nativeLanguageBinding) {
                        ForEach(NativeLanguage.selectable) { language in
                            Text(verbatim: language.endonym).tag(language)
                        }
                    } label: {
                        Text("I speak")
                            .font(.sniglet(.body))
                            .foregroundStyle(.primary)
                    }
                    .font(.sniglet(.body))
                }

                Picker(selection: $cefrLevelRaw) {
                    ForEach(CEFRLevel.allCases) { level in
                        Text("\(level.title) · \(level.subtitle)")
                            .tag(level.rawValue)
                    }
                } label: {
                    Text("My level")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }
                .font(.sniglet(.body))
                .onChange(of: cefrLevelRaw) {
                    // A manual level change restarts progress toward the
                    // next chat-based promotion at the new level.
                    UserDefaults.standard.set(0, forKey: OnboardingDefaultsKey.cefrPassesAtCurrentLevel)
                }

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

                Toggle(isOn: $liveActivityEnabled) {
                    Text("Live words on Lock Screen")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }
                .tint(DS.Color.ink)
                .onChange(of: liveActivityEnabled) { _, on in
                    if on { LiveActivityService.start() } else { LiveActivityService.end() }
                }
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.learning", defaultValue: "Learning", comment: "Settings section header for learning preferences (level, words per day, reminders)."))
            } footer: {
                Text("New words start at your level; easier ones only appear once your level runs out. Words you're already reviewing aren't affected.")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                ShareLink(item: AppStoreLinks.productURL,
                          message: Text("I've been learning words with Wordrus — thought you might like it too.")) {
                    Label("Share Wordrus", systemImage: "square.and.arrow.up")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }

                Button {
                    openURL(AppStoreLinks.writeReviewURL)
                } label: {
                    Label("Leave a Review", systemImage: "star.fill")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }
            } header: {
                sectionHeader("Spread the Word")
            }

            Section {
                Toggle(isOn: $analyticsEnabled) {
                    Text("Share anonymous usage stats")
                        .font(.sniglet(.body))
                        .foregroundStyle(.primary)
                }
                .tint(DS.Color.ink)
                .onChange(of: analyticsEnabled) { _, on in Analytics.isEnabled = on }
            } header: {
                sectionHeader("Privacy")
            } footer: {
                Text("Helps improve Wordrus. Nothing you type or say is ever sent.")
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
            PaywallView(source: .settings)
        }
        .alert(
            "Switch to \(pendingNativeLanguage.flatMap { TargetLanguage.offered(to: $0).first }?.titleInSentence ?? "")?",
            isPresented: Binding(
                get: { pendingNativeLanguage != nil },
                set: { if !$0 { pendingNativeLanguage = nil } }
            ),
            presenting: pendingNativeLanguage
        ) { native in
            Button("Switch") { applyNativeLanguage(native) }
            Button("Cancel", role: .cancel) { pendingNativeLanguage = nil }
        } message: { native in
            let target = TargetLanguage.offered(to: native).first?.titleInSentence ?? ""
            Text("\(native.endonym) speakers learn \(target) in Wordrus. Your current words and progress are kept and come back if you switch back.")
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
            restoreMessage = String(localized: "Your Pro membership has been restored.")
        case .nothingToRestore:
            restoreMessage = String(localized: "No previous purchases were found for this Apple Account.")
        case .failed(let message):
            restoreMessage = message
        }
    }

    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title).sectionHeaderStyle()
    }

    /// Changing native language only changes glosses while the current target
    /// is still one that language learns; otherwise it implies a target switch,
    /// which is confirmed first.
    private var nativeLanguageBinding: Binding<NativeLanguage> {
        Binding(
            get: { nativeLanguage },
            set: { newValue in
                guard newValue != nativeLanguage else { return }
                let current = OnboardingStore.targetLanguage ?? .spanish
                if TargetLanguage.offered(to: newValue).contains(current) {
                    applyNativeLanguage(newValue)
                } else {
                    pendingNativeLanguage = newValue
                }
            }
        )
    }

    /// Not paywalled like the deck picker's language switch: correcting who
    /// you are isn't choosing extra content, and the target that follows is
    /// forced by the pairing rule rather than picked.
    private func applyNativeLanguage(_ native: NativeLanguage) {
        NativeLanguage.current = native
        nativeLanguage = native
        pendingNativeLanguage = nil
        let current = OnboardingStore.targetLanguage ?? .spanish
        let offered = TargetLanguage.offered(to: native)
        if !offered.contains(current), let target = offered.first {
            SeedDataLoader.switchLanguage(to: target, context: context)
        } else {
            DailyWordService.refresh(context: context)
        }
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
