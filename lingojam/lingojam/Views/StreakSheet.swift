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
            Text("\(streak)")
                .font(.sniglet(.title3, weight: .bold))
                .foregroundStyle(streak > 0 ? StreakPalette.coralDeep : .secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Streak: \(streak) day\(streak == 1 ? "" : "s")")
    }
}

struct StreakSheet: View {
    @Query private var reviews: [ReviewLog]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            StreakCard(streak: currentStreak, weekActivity: weekActivity)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
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

    private var weekActivity: [StreakDayActivity] {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: .now)
        let reviewDays = Set(reviews.map { cal.startOfDay(for: $0.reviewedAt) })
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let labels = ["M", "T", "W", "T", "F", "S", "S"]
            return StreakDayActivity(
                label: labels[offset],
                date: day,
                isToday: cal.isDate(day, inSameDayAs: today),
                isFuture: day > today,
                didReview: reviewDays.contains(day)
            )
        }
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
    let weekActivity: [StreakDayActivity]

    @State private var celebrate = false

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
                    Text("\(streak) day\(streak == 1 ? "" : "s")")
                        .font(.sniglet(size: 28, weight: .bold))
                    Text(headline)
                        .font(.sniglet(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(weekActivity) { day in
                    VStack(spacing: 6) {
                        Text(day.label)
                            .font(.sniglet(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ZStack {
                            Circle()
                                .fill(fill(for: day))
                            if day.didReview {
                                Image(systemName: "checkmark")
                                    .font(.sniglet(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            } else if day.isToday {
                                Circle()
                                    .stroke(StreakPalette.coralDeep, lineWidth: 2)
                            }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .frame(maxWidth: .infinity)
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

    private var headline: String {
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
