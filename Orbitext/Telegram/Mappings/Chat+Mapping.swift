import Foundation

// MARK: - Chat domain mapping

//
// Converts typed TDApi.Chat -> ChatInfo. Caller (parseChatInfo) resolves
// the service-scoped fields (Saved Messages title override, online status
// from userCache) and maps lastMessage with MessageInfo(tdApi:service:).

extension TDApi.ChatType {
    enum Classification {
        case privateChat
        case basicGroup
        case supergroupGroup
        case supergroupChannel
        case secret
        case unknown
    }

    var classification: Classification {
        switch self {
        case .chatTypePrivate: return .privateChat
        case .chatTypeBasicGroup: return .basicGroup
        case .chatTypeSupergroup(let sg):
            return sg.isChannel ? .supergroupChannel : .supergroupGroup
        case .chatTypeSecret: return .secret
        case .unknown: return .unknown
        }
    }
}

extension TDApi.ChatPosition {
    var isMainList: Bool {
        if case .chatListMain = list { return true }
        return false
    }
}

extension TDApi.Chat {
    /// First position on the main chat list, if any. Mirrors the dict-walk
    /// behaviour (chats outside the main list contribute order=0).
    var mainListPosition: TDApi.ChatPosition? {
        positions.first { $0.isMainList }
    }
}

extension ChatInfo {
    /// Base mapping from a typed TDApi.Chat. The caller layers on
    /// service-scoped overrides (savedMessagesTitle, isOnline) and supplies
    /// lastMessage and reactionCount.
    init(
        tdApi chat: TDApi.Chat,
        lastMessage: MessageInfo?,
        reactionCount: Int,
        savedMessagesTitle: String? = nil,
        isOnline: Bool = false
    ) {
        let position = chat.mainListPosition
        let classification = chat.type?.classification ?? .unknown
        let isGroup = classification == .basicGroup || classification == .supergroupGroup
        let isChannel = classification == .supergroupChannel

        let photoFileId: String?
        if let small = chat.photo?.small {
            photoFileId = "\(Int64(small.id))"
        } else {
            photoFileId = nil
        }

        let isMuted = (chat.notificationSettings?.muteFor ?? 0) > 0
        let draft = chat.draftMessage.flatMap { ChatInfo.extractDraftText(from: $0) }

        self.init(
            id: chat.id,
            title: savedMessagesTitle ?? chat.title,
            lastMessage: lastMessage,
            unreadCount: Int(chat.unreadCount),
            photoFileId: photoFileId,
            isGroup: isGroup,
            isChannel: isChannel,
            isMuted: isMuted,
            order: position?.order ?? 0,
            isPinned: position?.isPinned ?? false,
            folderId: nil,
            draftMessage: draft,
            typingUserNames: [],
            typingActionKind: .none,
            isOnline: isOnline,
            lastReadOutboxMessageId: chat.lastReadOutboxMessageId,
            mentionCount: Int(chat.unreadMentionCount),
            reactionCount: reactionCount
        )
    }

    /// Pull display text from a typed DraftMessage if it carries a non-empty
    /// inputMessageText. Mirrors the legacy extractDraftText dict-walk so the
    /// typed path can sit alongside it during parity comparison.
    static func extractDraftText(from draft: TDApi.DraftMessage) -> String? {
        guard case .inputMessageText(let inputText) = draft.inputMessageText else {
            return nil
        }
        let text = inputText.text?.text ?? ""
        return text.isEmpty ? nil : text
    }
}
