import Foundation

/// Badge shown in the chat row's trailing column.
/// Priority: mention > reaction > message > none. Mention/reaction badges
/// are intentionally count-less - the icon itself signals
/// the type, and the surfaced unreadCount handles numeric density.
enum ChatBadgeKind: Equatable, Hashable {
    case none
    case message(Int)
    case mention
    case reaction
}

struct ChatInfo: Identifiable, Equatable, Hashable, Codable {
    let id: Int64
    var title: String
    var lastMessage: MessageInfo?
    var unreadCount: Int
    var photoFileId: String?
    var isGroup: Bool
    var isChannel = false
    var isMuted: Bool
    /// Place in the chat list the row belongs to: ChatStore stamps it from
    /// that list's entry. Rows from TDLib's mirror carry the Main list's.
    var order: Int64
    var isPinned = false
    var folderId: Int64? = nil
    var draftMessage: String? = nil
    var typingUserNames: [String] = []
    var typingActionKind: ChatActionKind = .none
    var isOnline = false
    var lastReadOutboxMessageId: Int64 = 0
    var mentionCount = 0
    var reactionCount = 0

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: ChatInfo, rhs: ChatInfo) -> Bool {
        // Compare every field that drives a visible row redraw. Omitting
        // a field here makes SwiftUI skip diffing the chat row even when
        // the underlying model changed - e.g. avatar updates from
        // updateChatPhoto were previously invisible because
        // photoFileId was not part of the equality check.
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.lastMessage?.id == rhs.lastMessage?.id
            && lhs.unreadCount == rhs.unreadCount
            && lhs.isMuted == rhs.isMuted
            && lhs.isPinned == rhs.isPinned
            && lhs.order == rhs.order
            && lhs.draftMessage == rhs.draftMessage
            && lhs.typingUserNames == rhs.typingUserNames
            && lhs.typingActionKind == rhs.typingActionKind
            && lhs.isOnline == rhs.isOnline
            && lhs.photoFileId == rhs.photoFileId
            && lhs.isGroup == rhs.isGroup
            && lhs.isChannel == rhs.isChannel
            && lhs.folderId == rhs.folderId
            && lhs.lastReadOutboxMessageId == rhs.lastReadOutboxMessageId
            && lhs.mentionCount == rhs.mentionCount
            && lhs.reactionCount == rhs.reactionCount
    }

    var badgeKind: ChatBadgeKind {
        if mentionCount > 0 { return .mention }
        if reactionCount > 0 { return .reaction }
        if unreadCount > 0 { return .message(unreadCount) }
        return .none
    }

    var hasDraft: Bool {
        guard let draft = draftMessage else { return false }
        return !draft.isEmpty
    }

    var isTyping: Bool {
        !typingUserNames.isEmpty
    }

    /// Stands in for a chat the directory does not hold yet.
    static func placeholder(id: Int64) -> ChatInfo {
        ChatInfo(
            id: id,
            title: "Chat",
            lastMessage: nil,
            unreadCount: 0,
            photoFileId: nil,
            isGroup: false,
            isMuted: false,
            order: 0
        )
    }
}

struct GroupInfo {
    var memberCount: Int?
    var description: String?
}
