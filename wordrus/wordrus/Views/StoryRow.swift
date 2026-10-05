import SwiftUI

/// The unread marker for story rows, like an unread message: a dot to the
/// left of the avatar, in the row's margin so the avatar stays aligned with
/// the call icons below it.
private struct UnreadDot: ViewModifier {
    let isUnread: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if isUnread {
                Circle()
                    .fill(LinearGradient(
                        colors: [DS.Color.coralLight, DS.Color.coralDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 10, height: 10)
                    .offset(x: -16)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A story in the Phone tab's Recents, styled like a message from Dr Tusk:
/// his avatar, the story's title, and when it arrived. Unread stories get a
/// dot before the avatar and an ink title.
struct StoryRow: View {
    let story: DailyStory

    var body: some View {
        let unread = !story.isOpened
        HStack(spacing: 12) {
            DrTuskAvatar(size: 40)
                .modifier(UnreadDot(isUnread: unread))
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(unread ? DS.Color.ink : Color.primary)
                    .lineLimit(2)
                Text(StoryTimestamp.string(for: story.createdAt))
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
/// Keeps its unread dot — opening the paywall doesn't count as reading; it
/// gives way to real story rows once the learner can play them.
struct StoryLockedRow: View {
    var isUnread: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            DrTuskAvatar(size: 40)
                .modifier(UnreadDot(isUnread: isUnread))
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
        .accessibilityValue(isUnread ? Text("Unread") : Text(verbatim: ""))
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
