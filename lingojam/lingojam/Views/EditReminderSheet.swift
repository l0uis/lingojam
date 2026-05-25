import SwiftUI
import SwiftData

struct EditReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    @AppStorage(OnboardingDefaultsKey.notificationsEnabled) private var notificationsEnabled: Bool = false
    @AppStorage(OnboardingDefaultsKey.notificationsPerDay) private var notificationsPerDay: Int = 10
    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage(DeckConstants.selectedCEFRLevelDefaultsKey) private var selectedCEFRLevel: String = DeckConstants.defaultCEFRLevel

    @State private var startDate: Date = .now
    @State private var endDate: Date = .now
    @State private var daysOfWeek: Set<Int> = OnboardingStore.notificationDaysOfWeek

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Reminders", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, newValue in
                            if newValue {
                                Task { await NotificationService.requestAuthorization() }
                            }
                        }
                }

                Section {
                    NavigationLink {
                        WordFilterPicker(
                            decks: decks,
                            selectedSlug: $selectedDeckSlug,
                            selectedLevel: $selectedCEFRLevel
                        )
                    } label: {
                        LabeledContent("Type of words", value: wordFilterSummary)
                    }
                    .disabled(!notificationsEnabled)

                    Stepper(value: $notificationsPerDay, in: 1...10) {
                        LabeledContent("How many", value: "\(notificationsPerDay)x")
                    }
                    .disabled(!notificationsEnabled)

                    DatePicker("Start at", selection: $startDate, displayedComponents: .hourAndMinute)
                        .disabled(!notificationsEnabled)
                    DatePicker("End at", selection: $endDate, displayedComponents: .hourAndMinute)
                        .disabled(!notificationsEnabled)
                }

                Section("Repeat") {
                    DayOfWeekPicker(selection: $daysOfWeek)
                        .disabled(!notificationsEnabled)
                }
            }
            .navigationTitle("Edit reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                startDate = date(from: OnboardingStore.notificationStart)
                endDate = date(from: OnboardingStore.notificationEnd)
            }
        }
    }

    private var wordFilterSummary: String {
        let deckName: String
        if selectedDeckSlug == DeckConstants.allSlug {
            deckName = "All words"
        } else if let deck = decks.first(where: { $0.slug == selectedDeckSlug }) {
            deckName = deck.displayName
        } else {
            deckName = "All words"
        }
        if selectedCEFRLevel == DeckConstants.allLevelsValue {
            return deckName
        }
        return "\(deckName) · \(selectedCEFRLevel)"
    }

    private func save() {
        OnboardingStore.setNotificationStart(components(from: startDate))
        OnboardingStore.setNotificationEnd(components(from: endDate))
        OnboardingStore.notificationDaysOfWeek = daysOfWeek

        if notificationsEnabled, let snapshot = DailyWordSnapshot.load() {
            NotificationService.scheduleReminders(
                using: snapshot,
                perDay: notificationsPerDay,
                start: components(from: startDate),
                end: components(from: endDate),
                daysOfWeek: daysOfWeek
            )
        } else if !notificationsEnabled {
            NotificationService.cancelAllReminders()
        }
        dismiss()
    }

    private func date(from components: DateComponents) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: components.hour ?? 9, minute: components.minute ?? 0, second: 0, of: .now) ?? .now
    }

    private func components(from date: Date) -> DateComponents {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return DateComponents(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
    }
}

private struct WordFilterPicker: View {
    let decks: [Deck]
    @Binding var selectedSlug: String
    @Binding var selectedLevel: String

    var body: some View {
        Form {
            Section("Level") {
                ForEach(DeckConstants.cefrLevels, id: \.self) { level in
                    row(title: level, value: level, binding: $selectedLevel)
                }
            }
            Section("Deck") {
                row(title: "All Words", value: DeckConstants.allSlug, binding: $selectedSlug)
                ForEach(decks, id: \.slug) { deck in
                    row(title: deck.displayName, value: deck.slug, binding: $selectedSlug)
                }
            }
        }
        .navigationTitle("Type of words")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(title: String, value: String, binding: Binding<String>) -> some View {
        Button {
            binding.wrappedValue = value
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if binding.wrappedValue == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DayOfWeekPicker: View {
    @Binding var selection: Set<Int>

    private let labels: [(weekday: Int, short: String)] = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(labels, id: \.weekday) { item in
                Button {
                    if selection.contains(item.weekday) {
                        selection.remove(item.weekday)
                    } else {
                        selection.insert(item.weekday)
                    }
                } label: {
                    Text(item.short)
                        .font(.sniglet(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            Circle()
                                .fill(selection.contains(item.weekday) ? Color.accentColor : Color.secondary.opacity(0.18))
                                .frame(width: 36, height: 36)
                        )
                        .foregroundStyle(selection.contains(item.weekday) ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    EditReminderSheet()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
