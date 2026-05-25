import SwiftUI
import SwiftData

@main
struct lingojamApp: App {
    init() {
        FontRegistrar.registerOnce()
        NotificationDelegate.shared.register()
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
            RootView()
                .task {
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
                    guard url.scheme == "lingojam", url.host == "word" else { return }
                    let id = url.lastPathComponent
                    guard !id.isEmpty, id != "word" else { return }
                    UserDefaults.standard.set(id, forKey: DeepLink.pendingWordIDKey)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
