import SwiftUI
import SwiftData
#if canImport(RevenueCat)
import RevenueCat
#endif

@main
struct wordrusApp: App {
    init() {
        FontRegistrar.registerOnce()
        NotificationDelegate.shared.register()
        #if canImport(RevenueCat)
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: RevenueCatConfig.apiKey)
        #endif
        if let sniglet = UIFont(name: "Sniglet-Regular", size: 14) {
            UISegmentedControl.appearance().setTitleTextAttributes(
                [.font: sniglet], for: .normal
            )
            UISegmentedControl.appearance().setTitleTextAttributes(
                [.font: sniglet], for: .selected
            )
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VocabularyWord.self,
            LearningProgress.self,
            ReviewLog.self,
            Deck.self,
            ChatSession.self,
            ChatMessage.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPreviewPaywall") {
                // Launch straight into the paywall for visual QA / screenshots:
                //   xcrun simctl launch <udid> <bundle> -uiPreviewPaywall
                PaywallView()
                    .preferredColorScheme(.light)
            } else {
                rootScene
            }
            #else
            rootScene
            #endif
        }
        .modelContainer(sharedModelContainer)
    }

    private var rootScene: some View {
        RootView()
                .preferredColorScheme(.light)
                .task {
                    // Start observing Pro entitlement. Uses RevenueCat once
                    // the package is added; otherwise the free provider keeps
                    // everything building (see REVENUECAT_SETUP.md).
                    #if canImport(RevenueCat)
                    Entitlements.shared.bootstrap(provider: RevenueCatEntitlementsProvider())
                    #else
                    Entitlements.shared.start()
                    #endif
                    SeedDataLoader.seedIfNeeded(sharedModelContainer.mainContext)
                    DeckSyncMigrator.sync(sharedModelContainer.mainContext)
                    LearningProgressMigrator.retireFirstTimeKnownWords(sharedModelContainer.mainContext)
                    VocabularyLevelMigrator.migrateIfNeeded()
                    MissedCallReconciler.reconcileIfNeeded(sharedModelContainer.mainContext)
                    DailyWordService.refresh(context: sharedModelContainer.mainContext)
                    if OnboardingStore.hasCompleted {
                        await NotificationService.requestAuthorizationIfNeeded()
                        NotificationService.scheduleWalrusCalls()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "wordrus", url.host == "word" else { return }
                    let id = url.lastPathComponent
                    guard !id.isEmpty, id != "word" else { return }
                    UserDefaults.standard.set(id, forKey: DeepLink.pendingWordIDKey)
                }
    }
}
