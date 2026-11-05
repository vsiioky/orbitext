import Foundation
import os

// Typed dispatch for TDLib `update*` events. handleUpdate calls
// handleUpdateTyped(_:) first; on `true` the typed branch already handled
// the event, on `false` we fall through to the dict walk in
// TDLibService+Updates.swift.
//
// Covers the leaf updates that don't need ChatInfo/MessageInfo/UserInfo
// mapping. Complex updates return false so the handler in
// TDLibService+Updates.swift runs. The three message updates also return
// false when chat_id or message_id is missing; no handler wants those.

extension TDLibService {
    func handleUpdateTyped(_ dict: [String: Any]) -> Bool {
        // Route before decoding: complex updates are handled by the legacy
        // parser below. Decoding their complete Chat/Message/User trees here
        // only to discard them doubles parsing work during initial sync.
        guard let type = dict["@type"] as? String else { return false }
        switch type {
        case "updateMessageContent":
            let u = TDApi.decodeUpdateMessageContent(dict)
            // Content delta: invalidate cached properties so any open menu
            // refetches, then hand the new content to the chat store.
            guard u.chatId != 0, u.messageId != 0 else { return false }
            emit(.messagePropertiesInvalidated(chatId: u.chatId, messageId: u.messageId))
            if let newContent = u.newContent {
                emit(.messageContentChanged(
                    chatId: u.chatId,
                    messageId: u.messageId,
                    content: MessageContent(tdApi: newContent)
                ))
            }
            return true

        case "updateMessageEdited":
            let u = TDApi.decodeUpdateMessageEdited(dict)
            guard u.chatId != 0, u.messageId != 0 else { return false }
            emit(.messagePropertiesInvalidated(chatId: u.chatId, messageId: u.messageId))
            // reply_markup is the message's complete markup after the edit;
            // null removes it.
            emit(.messageReplyMarkupChanged(
                chatId: u.chatId,
                messageId: u.messageId,
                replyMarkup: u.replyMarkup.flatMap(ReplyMarkup.init(tdApi:))
            ))
            return true

        case "updateMessageContentOpened":
            let u = TDApi.decodeUpdateMessageContentOpened(dict)
            guard u.chatId != 0, u.messageId != 0 else { return false }
            emit(.messageContentOpened(chatId: u.chatId, messageId: u.messageId))
            return true

        case "updateDeleteMessages":
            let u = TDApi.decodeUpdateDeleteMessages(dict)
            guard u.isPermanent else { return true }
            emit(.deleteMessages(chatId: u.chatId, messageIds: u.messageIds))
            return true

        case "updateMessageInteractionInfo":
            let u = TDApi.decodeUpdateMessageInteractionInfo(dict)
            emit(.reactionsUpdated(
                chatId: u.chatId,
                messageId: u.messageId,
                reactions: ReactionInfo.list(tdApi: u.interactionInfo?.reactions?.reactions ?? [])
            ))
            return true

        case "updateChatUnreadMentionCount":
            let u = TDApi.decodeUpdateChatUnreadMentionCount(dict)
            let count = Int(u.unreadMentionCount)
            _ = chatCache.mutate(u.chatId) { $0.mentionCount = count }
            emit(.chatMentionCountChanged(chatId: u.chatId, count: count))
            return true

        case "updateChatTitle":
            let u = TDApi.decodeUpdateChatTitle(dict)
            if let chat = chatCache.mutate(u.chatId, { $0.title = u.title }) {
                emit(.chatUpdated(chat))
            }
            return true

        case "updateChatReadInbox":
            let u = TDApi.decodeUpdateChatReadInbox(dict)
            if let chat = chatCache.mutate(u.chatId, { $0.unreadCount = Int(u.unreadCount) }) {
                emit(.chatUpdated(chat))
            }
            return true

        case "updateChatReadOutbox":
            let u = TDApi.decodeUpdateChatReadOutbox(dict)
            if let chat = chatCache.mutate(u.chatId, {
                $0.lastReadOutboxMessageId = u.lastReadOutboxMessageId
            }) {
                emit(.chatUpdated(chat))
            }
            return true

        case "updateChatPhoto":
            let u = TDApi.decodeUpdateChatPhoto(dict)
            let fileId: String?
            if let smallId = u.photo?.small?.id {
                fileId = "\(Int64(smallId))"
            } else {
                fileId = nil
            }
            if let chat = chatCache.mutate(u.chatId, { $0.photoFileId = fileId }) {
                emit(.chatUpdated(chat))
            }
            return true

        case "updateChatPosition":
            let u = TDApi.decodeUpdateChatPosition(dict)
            // The mirror keeps the Main values only; the event carries the
            // list that changed, so the repository can follow any of them.
            guard let position = u.position.flatMap(ChatListPosition.init(tdApi:)) else { return true }
            let chat: ChatInfo?
            if position.list == .main {
                chat = chatCache.mutate(u.chatId) {
                    $0.order = position.order
                    $0.isPinned = position.isPinned
                }
            } else {
                chat = chatCache.get(u.chatId)
            }
            if let chat {
                emit(.chatPositionChanged(.init(chat: chat, positions: [position], source: .explicitPosition)))
            }
            return true

        case "updateChatNotificationSettings":
            let u = TDApi.decodeUpdateChatNotificationSettings(dict)
            let muted = (u.notificationSettings?.muteFor ?? 0) > 0
            if let chat = chatCache.mutate(u.chatId, { $0.isMuted = muted }) {
                emit(.chatUpdated(chat))
            }
            return true

        case "updateConnectionState":
            let u = TDApi.decodeUpdateConnectionState(dict)
            let raw = connectionStateRawName(u.state)
            Logger.tdlib.info("connection state: \(raw, privacy: .public)")
            emit(.connectionStateChanged(TDLibConnectionPhase(rawTDLibState: raw)))
            return true

        case "updateUserStatus":
            let u = TDApi.decodeUpdateUserStatus(dict)
            let isOnline: Bool
            if case .userStatusOnline = u.status {
                isOnline = true
            } else {
                isOnline = false
            }
            // Keep the cached user's presence current: chat rows built later
            // read it from the cache.
            let userId = u.userId
            if userId != 0, u.status != nil {
                let status = UserInfo.Status(tdApi: u.status)
                userCache.mutate(userId) { $0.status = status }
            }
            if let chat = chatCache.mutate(userId, { $0.isOnline = isOnline }) {
                emit(.chatUpdated(chat))
            }
            return true

        default:
            // updateAuthorizationState / updateNewChat / updateNewMessage /
            // updateChatLastMessage / updateChatDraftMessage / updateUser /
            // updateFile / updateChatAction / notifications / folders ->
            // dict handlers in TDLibService+Updates.swift.
            return false
        }
    }

    private func connectionStateRawName(_ state: TDApi.ConnectionState?) -> String {
        switch state {
        case .connectionStateWaitingForNetwork: return "connectionStateWaitingForNetwork"
        case .connectionStateConnectingToProxy: return "connectionStateConnectingToProxy"
        case .connectionStateConnecting: return "connectionStateConnecting"
        case .connectionStateUpdating: return "connectionStateUpdating"
        case .connectionStateReady: return "connectionStateReady"
        case .unknown(let tag): return tag
        case .none: return ""
        }
    }
}

extension ChatActionKind {
    init(tdApi action: TDApi.ChatAction?) {
        guard let action else { self = .none
        return
        }
        switch action {
        case .chatActionTyping: self = .typing
        case .chatActionRecordingVoiceNote: self = .recordingVoice
        case .chatActionUploadingVoiceNote: self = .uploadingVoice
        case .chatActionRecordingVideoNote: self = .recordingVideo
        case .chatActionUploadingVideoNote: self = .uploadingVideoNote
        case .chatActionUploadingPhoto: self = .uploadingPhoto
        case .chatActionUploadingVideo: self = .uploadingVideo
        case .chatActionUploadingDocument: self = .uploadingDocument
        case .chatActionChoosingSticker: self = .choosingSticker
        case .chatActionChoosingLocation: self = .choosingLocation
        case .chatActionChoosingContact: self = .choosingContact
        case .chatActionStartPlayingGame: self = .playingGame
        case .chatActionRecordingVideo,
             .chatActionWatchingAnimations,
             .chatActionCancel,
             .unknown:
            self = .none
        }
    }
}
