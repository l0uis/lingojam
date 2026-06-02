import SwiftUI

struct SettingsView: View {
    let onRestartOnboarding: () -> Void

    @AppStorage(OnboardingDefaultsKey.displayName) private var displayName: String = ""
    @AppStorage(OnboardingDefaultsKey.notificationsEnabled) private var notificationsEnabled: Bool = false
    @AppStorage(OnboardingDefaultsKey.notificationsPerDay) private var notificationsPerDay: Int = 10
    @AppStorage(DailySetConfig.defaultsKey) private var dailySetSize: Int = DailySetConfig.defaultSize

    @State private var isEditingReminder: Bool = false
    @State private var isShowingWidgetSheet: Bool = false

    var body: some View {
        Form {
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

                Button {
                    isEditingReminder = true
                } label: {
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
                }
                .buttonStyle(.plain)

                Button {
                    isShowingWidgetSheet = true
                } label: {
                    HStack {
                        Text("Widget")
                            .font(.sniglet(.body))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.sniglet(.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                sectionHeader("Learning")
            }

            #if DEBUG
            Section {
                Button(role: .destructive) {
                    onRestartOnboarding()
                } label: {
                    Label("Restart onboarding", systemImage: "arrow.counterclockwise")
                        .font(.sniglet(.body))
                }
            } header: {
                sectionHeader("Debug")
            } footer: {
                Text("Resets onboarding answers and shows the flow again. Debug builds only.")
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
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).sectionHeaderStyle()
    }

}

#Preview {
    NavigationStack {
        SettingsView(onRestartOnboarding: {})
    }
}
