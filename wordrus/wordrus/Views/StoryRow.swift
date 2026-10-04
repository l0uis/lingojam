import SwiftUI

/// A story in the Phone tab's Recents, styled like a message from Dr Tusk:
/// his avatar, the story's title, and when it arrived. Unread stories look
/// like missed calls — red title plus a dot, so it doesn't rely on colour.
struct StoryRow: View {
    let story: DailyStory

    var body: some View {
        let unread = !story.isOpened
        HStack(spacing: 12) {
            DrTuskAvatar(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(unread ? Color.red : Color.primary)
                    .lineLimit(2)
                Text(StoryTimestamp.string(for: story.createdAt))
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if unread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread
            ? Text("Unread story from Dr Tusk: \(story.title). \(StoryTimestamp.string(for: story.createdAt))")
            : Text("Story from Dr Tusk: \(story.title). \(StoryTimestamp.string(for: story.createdAt))"))
        .accessibilityAddTraits(.isButton)
    }
}

/// What free users see instead of stories: Dr Tusk's stories are Pro.
struct StoryLockedRow: View {
    var body: some View {
        HStack(spacing: 12) {
            DrTuskAvatar(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily stories from Dr Tusk")
                    .font(.sniglet(.headline))
                Text("A short story with your words every day. Unlock with Pro.")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .foregroundStyle(DS.Color.ink)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Stands in for today's story until it's written (or if writing it failed).
struct TodayStoryPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            DrTuskAvatar(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today's story")
                    .font(.sniglet(.headline))
                Text("Dr Tusk is writing it…")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The Phone tab's badge: unread stories in the active language. Stories are
/// Pro, so free users never see one.
enum StoryBadge {
    static func unreadCount(stories: [DailyStory], languageRaw: String?, isPro: Bool) -> Int {
        guard isPro, let languageRaw else { return 0 }
        return stories.filter { $0.languageRaw == languageRaw && !$0.isOpened }.count
    }
}

/// One line of the Phone tab's Recents: a call or a story, newest first.
enum RecentItem: Identifiable {
    case call(ChatSession)
    case story(DailyStory)

    var id: String {
        switch self {
        case .call(let session): "call-\(session.id.uuidString)"
        case .story(let story): "story-\(story.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .call(let session): session.startedAt
        case .story(let story): story.createdAt
        }
    }

    static func merged(calls: [ChatSession], stories: [DailyStory]) -> [RecentItem] {
        (calls.map(RecentItem.call) + stories.map(RecentItem.story)).sorted { $0.date > $1.date }
    }
}
