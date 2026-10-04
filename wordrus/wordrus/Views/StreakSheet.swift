import SwiftUI
import SwiftData

private enum StreakPalette {
    static let coralLight = Color(red: 0xFB / 255.0, green: 0x78 / 255.0, blue: 0xA8 / 255.0)
    static let coralDeep = Color(red: 0xFE / 255.0, green: 0x47 / 255.0, blue: 0x61 / 255.0)
}

struct StreakBadge: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 4) {
            Image("coral")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
            Text(verbatim: "\(streak)")
                .font(.sniglet(.title3, weight: .bold))
                .foregroundStyle(streak > 0 ? StreakPalette.coralDeep : .secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Streak: \(streak) days")
    }
}

struct StreakSheet: View {
    @Query private var reviews: [ReviewLog]
    @Query private var sessions: [ChatSession]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StreakCard(
                    streak: currentStreak,
                    monthTitle: monthTitle,
                    leadingBlanks: monthData.leadingBlanks,
                    monthDays: monthData.days
                )
                    .padding(.top, 8)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    StreakStatTile(
                        count: bestStreak,
                        label: "Best streak",
                        phrase: "\(bestStreak) days",
                        systemIcon: "trophy.fill",
                        tint: .orange
                    )
                    StreakStatTile(
                        count: totalSessions,
                        label: "Total sessions",
                        phrase: "\(totalSessions) calls",
                        systemIcon: "phone.fill",
                        tint: .blue
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }

    // MARK: - Streak calculations

    private var currentStreak: Int {
        let cal = Calendar.current
        let reviewDays = Set(reviews.map { cal.startOfDay(for: $0.reviewedAt) })
        guard !reviewDays.isEmpty else { return 0 }
        var streak = 0
        var day = cal.startOfDay(for: .now)
        if !reviewDays.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            if !reviewDays.contains(day) { return 0 }
        }
        while reviewDays.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Longest run of consecutive review days the user has ever recorded.
    private var bestStreak: Int {
        let cal = Calendar.current
        let days = Set(reviews.map { cal.startOfDay(for: $0.reviewedAt) })
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1
        var run = 1
        for i in 1..<sorted.count {
            if let prev = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               cal.isDate(prev, inSameDayAs: sorted[i]) {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }

    /// Title for the calendar overview — the current month's name.
    private var monthTitle: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMM")
        return fmt.string(from: .now)
    }

    /// Per-day activity for the current calendar month, plus the number of
    /// blank leading cells needed to align the 1st under its weekday (Monday
    /// first).
    private var monthData: (leadingBlanks: Int, days: [StreakDayActivity]) {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: .now)
        let reviewDays = Set(reviews.map { cal.startOfDay(for: $0.reviewedAt) })
        guard let monthStart = cal.dateInterval(of: .month, for: today)?.start,
              let dayRange = cal.range(of: .day, in: .month, for: today) else {
            return (0, [])
        }
        let weekday = cal.component(.weekday, from: monthStart) // 1 = Sunday
        let leading = (weekday - cal.firstWeekday + 7) % 7
        let days: [StreakDayActivity] = dayRange.compactMap { dayNum in
            guard let day = cal.date(byAdding: .day, value: dayNum - 1, to: monthStart) else { return nil }
            let start = cal.startOfDay(for: day)
            return StreakDayActivity(
                label: "\(dayNum)",
                date: start,
                isToday: cal.isDate(start, inSameDayAs: today),
                isFuture: start > today,
                didReview: reviewDays.contains(start)
            )
        }
        return (leading, days)
    }

    // MARK: - Aggregate stats

    private var totalSessions: Int {
        sessions.count
    }
}

private struct StreakStatTile: View {
    let count: Int
    let label: LocalizedStringResource
    /// The count with its unit ("12 days"), one plural-aware key.
    let phrase: LocalizedStringResource
    let systemIcon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemIcon)
                    .font(.sniglet(.subheadline, weight: .bold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.sniglet(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            Text(AttributedString(localized: phrase, emphasizingCount: count,
                                  font: .sniglet(size: 30, weight: .bold), color: tint))
                .font(.sniglet(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StreakDayActivity: Identifiable {
    let id = UUID()
    let label: String
    let date: Date
    let isToday: Bool
    let isFuture: Bool
    let didReview: Bool
}

private struct StreakCard: View {
    let streak: Int
    let monthTitle: String
    let leadingBlanks: Int
    let monthDays: [StreakDayActivity]

    @State private var celebrate = false

    /// Monday-first single-letter weekday headers in the user's locale.
    private let weekdayLabels: [String] = {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return Array(symbols.dropFirst()) + symbols.prefix(1)
    }()
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image("coral")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .opacity(streak > 0 ? 1.0 : 0.4)
                    .scaleEffect(celebrate ? 1.2 : 1.0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.5), value: celebrate)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streak) days")
                        .font(.sniglet(size: 28, weight: .bold))
                    Text(headline)
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                HStack {
                    Text(monthTitle)
                        .font(.sniglet(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.sniglet(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(0..<leadingBlanks, id: \.self) { _ in
                        Color.clear.frame(height: 28)
                    }
                    ForEach(monthDays) { day in
                        ZStack {
                            Circle()
                                .fill(fill(for: day))
                            if day.didReview {
                                Image(systemName: "checkmark")
                                    .font(.sniglet(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else if day.isToday {
                                Circle()
                                    .stroke(StreakPalette.coralDeep, lineWidth: 2)
                            } else {
                                Text(day.label)
                                    .font(.sniglet(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 28)
                    }
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: streak > 0
                    ? [StreakPalette.coralLight.opacity(0.22), StreakPalette.coralDeep.opacity(0.18)]
                    : [Color.secondary.opacity(0.08), Color.secondary.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .onAppear {
            if streak > 0 { celebrate = true }
        }
    }

    private var headline: LocalizedStringResource {
        if streak == 0 { return "Start your streak today" }
        if streak == 1 { return "Nice start — keep it going!" }
        if streak < 7 { return "You're on a roll!" }
        if streak < 30 { return "Incredible momentum!" }
        return "Legendary streak!"
    }

    private func fill(for day: StreakDayActivity) -> Color {
        if day.didReview { return StreakPalette.coralDeep }
        if day.isFuture { return Color.secondary.opacity(0.1) }
        return Color.secondary.opacity(0.18)
    }
}

// MARK: - Toolbar modifier

private struct StreakToolbarModifier: ViewModifier {
    @Query private var reviews: [ReviewLog]
    @State private var isShowingStreak: Bool = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingStreak = true
                    } label: {
                        StreakBadge(streak: currentStreak)
                    }
                }
            }
            .sheet(isPresented: $isShowingStreak) {
                StreakSheet()
            }
    }

    private var currentStreak: Int {
        let cal = Calendar.current
        let reviewDays = Set(reviews.map { cal.startOfDay(for: $0.reviewedAt) })
        guard !reviewDays.isEmpty else { return 0 }
        var streak = 0
        var day = cal.startOfDay(for: .now)
        if !reviewDays.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            if !reviewDays.contains(day) { return 0 }
        }
        while reviewDays.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }
}

extension View {
    /// Adds the coral streak badge to the navigation bar's top-right; tapping
    /// it presents the streak sheet. Apply once per top-level tab view.
    func streakToolbar() -> some View {
        modifier(StreakToolbarModifier())
    }
}

#Preview {
    StreakSheet()
        .modelContainer(for: [ReviewLog.self], inMemory: true)
}
