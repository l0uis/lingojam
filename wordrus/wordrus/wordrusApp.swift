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
        // Must run before the app finishes launching so the handler is ready
        // if iOS relaunches us for a background rotation.
        LiveActivityService.registerBackgroundTask()
        StoryScheduler.registerBackgroundTask(container: sharedModelContainer)
        // Anonymous usage analytics (PostHog). No-op until the project token is set.
        Analytics.configure()
        #if canImport(RevenueCat)
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: RevenueCatConfig.apiKey)
        // Join RevenueCat's purchase / renewal events to the same anonymous person.
        if let posthogID = Analytics.distinctId {
            Purchases.shared.attribution.setPostHogUserID(posthogID)
        }
        #endif
        #if DEBUG
        // The `-uiPreviewPaywall` scene renders PaywallView outside
        // `rootScene`, so it never reached rootScene's bootstrap and fell back
        // to `FreeEntitlementsProvider` — the preview then showed hardcoded
        // placeholder pricing that looked exactly like a working live paywall.
        // Bootstrap here, before any view exists, so the preview shows real
        // store data (or honestly fails to load it).
        if ProcessInfo.processInfo.arguments.contains("-uiPreviewPaywall") {
            #if canImport(RevenueCat)
            MainActor.assumeIsolated {
                Entitlements.shared.bootstrap(provider: RevenueCatEntitlementsProvider())
            }
            #endif
        }
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
            DailyStory.self,
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
                    // Re-attach / advance the Live Activity if the user has it on.
                    LiveActivityService.start()
                    if OnboardingStore.hasCompleted {
                        await NotificationService.requestAuthorizationIfNeeded()
                        NotificationService.scheduleWalrusCalls()
                    }
                    // Have today's story waiting rather than written on tap.
                    await StoryScheduler.prepareTodayStory(context: sharedModelContainer.mainContext)
                }
                .onOpenURL { url in
                    guard url.scheme == "wordrus", url.host == "word" else { return }
                    let id = url.lastPathComponent
                    guard !id.isEmpty, id != "word" else { return }
                    Task { @MainActor in DeepLinkCoordinator.shared.request(wordID: id) }
                }
    }
}
