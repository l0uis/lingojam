import SwiftUI
import SwiftData

struct EditReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    @AppStorage(OnboardingDefaultsKey.notificationsEnabled) private var notificationsEnabled: Bool = false
    @AppStorage(OnboardingDefaultsKey.notificationsPerDay) private var notificationsPerDay: Int = 10
    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug

    @State private var startDate: Date = .now
    @State private var endDate: Date = .now
    @State private var daysOfWeek: Set<Int> = OnboardingStore.notificationDaysOfWeek

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $notificationsEnabled) {
                        Text("Reminders").font(.sniglet(.body))
                    }
                    .tint(DS.Color.ink)
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
                            selectedSlug: $selectedDeckSlug
                        )
                    } label: {
                        LabeledContent {
                            Text(wordFilterSummary).font(.sniglet(.body))
                        } label: {
                            Text("Type of words").font(.sniglet(.body))
                        }
                    }
                    .disabled(!notificationsEnabled)

                    Stepper(value: $notificationsPerDay, in: 1...10) {
                        LabeledContent {
                            Text("\(notificationsPerDay)x").font(.sniglet(.body))
                        } label: {
                            Text("How many").font(.sniglet(.body))
                        }
                    }
                    .disabled(!notificationsEnabled)

                    DatePicker(selection: $startDate, displayedComponents: .hourAndMinute) {
                        Text("Start at").font(.sniglet(.body))
                    }
                    .disabled(!notificationsEnabled)

                    DatePicker(selection: $endDate, displayedComponents: .hourAndMinute) {
                        Text("End at").font(.sniglet(.body))
                    }
                    .disabled(!notificationsEnabled)
                }

                Section {
                    DayOfWeekPicker(selection: $daysOfWeek)
                        .disabled(!notificationsEnabled)
                } header: {
                    sectionHeader("Repeat")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Color.paper.ignoresSafeArea())
            .gochiHandNavigationTitle("Edit reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.sniglet(.body))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .font(.sniglet(.body, weight: .semibold))
                }
            }
            .onAppear {
                startDate = date(from: OnboardingStore.notificationStart)
                endDate = date(from: OnboardingStore.notificationEnd)
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title).sectionHeaderStyle()
    }

    private var wordFilterSummary: String {
        let deckName: String
        if selectedDeckSlug == DeckConstants.allSlug {
            deckName = String(localized: "All words")
        } else if let deck = decks.first(where: { $0.slug == selectedDeckSlug }) {
            deckName = deck.localizedName
        } else {
            deckName = String(localized: "All words")
        }
        return deckName
    }

    private func save() {
        OnboardingStore.setNotificationStart(components(from: startDate))
        OnboardingStore.setNotificationEnd(components(from: endDate))
        OnboardingStore.notificationDaysOfWeek = daysOfWeek

        if notificationsEnabled {
            NotificationService.scheduleReminders(
                using: NotificationService.reminderStack(fallback: DailyWordSnapshot.load()),
                perDay: notificationsPerDay,
                start: components(from: startDate),
                end: components(from: endDate),
                daysOfWeek: daysOfWeek
            )
        } else {
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

    var body: some View {
        Form {
            Section {
                row(title: String(localized: "All Words"), value: DeckConstants.allSlug, binding: $selectedSlug)
                ForEach(decks, id: \.slug) { deck in
                    row(title: deck.localizedName, value: deck.slug, binding: $selectedSlug)
                }
            } header: {
                Text("Deck").sectionHeaderStyle()
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Color.paper.ignoresSafeArea())
        .gochiHandNavigationTitle("Type of words", size: 24)
    }

    private func row(title: String, value: String, binding: Binding<String>) -> some View {
        Button {
            binding.wrappedValue = value
        } label: {
            HStack {
                Text(title)
                    .font(.sniglet(.body))
                    .foregroundStyle(Color.whiteboardInk)
                Spacer()
                if binding.wrappedValue == value {
                    Image(systemName: "checkmark")
                        .font(.sniglet(.body, weight: .semibold))
                        .foregroundStyle(DS.Color.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DayOfWeekPicker: View {
    @Binding var selection: Set<Int>

    /// One-letter weekday initials (Sunday first, matching `Calendar`'s
    /// weekday numbering) from the system, so they follow the app language.
    private var labels: [(weekday: Int, short: String)] {
        Calendar.current.veryShortStandaloneWeekdaySymbols.enumerated().map { (weekday: $0.offset + 1, short: $0.element) }
    }

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
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(selection.contains(item.weekday) ? DS.Color.ink : DS.Color.inkTint)
                        )
                        .foregroundStyle(selection.contains(item.weekday) ? Color.white : DS.Color.ink)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    EditReminderSheet()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
