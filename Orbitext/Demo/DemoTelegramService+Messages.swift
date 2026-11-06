#if DEBUG
import Foundation

// MARK: - Messages

extension DemoTelegramService {
    /// Newest first, `limit` of them older than `fromMessageId` (0 for the latest).
    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] {
        let thread = state.withLock { $0.messages[chatId] ?? [] }
        guard fromMessageId != 0 else { return Array(thread.suffix(limit).reversed()) }
        guard let anchor = thread.firstIndex(where: { $0.id == fromMessageId }) else { return [] }
        return Array(thread[max(0, anchor - limit)..<anchor].reversed())
    }

    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo] {
        let needle = query.lowercased()
        let candidates = state.withLock { state in
            state.messages.filter { chatId == nil || $0.key == chatId }.values.flatMap(\.self)
        }
        return candidates
            .filter { $0.currentText?.lowercased().contains(needle) == true }
            .sorted { $0.date > $1.date }
    }

    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        let message = state.withLock { $0.messages[chatId]?.first { $0.id == messageId } }
        let isOutgoing = message?.isOutgoing ?? false
        var properties = MessageProperties()
        properties.canBeEdited = isOutgoing && message?.currentText != nil
        properties.canBeDeletedOnlyForSelf = true
        properties.canBeDeletedForAllUsers = isOutgoing
        properties.isResolved = true
        return properties
    }

    // MARK: Sending

    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        append(chatId: chatId, content: .text(FormattedString(text: text)), replyTo: replyToMessageId)
    }

    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo {
        append(chatId: chatId, content: .voice(duration: duration, fileId: DemoMedia.voiceFileId, waveform: nil))
    }

    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo {
        let content = MessageContent.sticker(
            emoji: sticker.emoji, fileId: sticker.fileId, thumbnailFileId: sticker.thumbnailFileId
        )
        return append(chatId: chatId, content: content)
    }

    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo {
        append(chatId: chatId, content: .location(latitude: location.latitude, longitude: location.longitude, livePeriod: nil))
    }

    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws {}

    func sendTyping(chatId: Int64) async throws {}

    /// Stores an outgoing message and announces it, as TDLib does before it
    /// answers the send.
    private func append(chatId: Int64, content: MessageContent, replyTo: Int64? = nil) -> MessageInfo {
        let me = self.content.me
        let message = state.withLock { state -> MessageInfo in
            var message = MessageInfo(
                id: (state.messages[chatId]?.last?.id ?? 0) + 1, chatId: chatId, senderName: me.fullName,
                senderId: me.id, content: content, date: .now, isOutgoing: true, isRead: false,
                replyToMessageId: replyTo
            )
            if let replyTo, let original = state.messages[chatId]?.first(where: { $0.id == replyTo }) {
                message.replyToSenderName = original.senderName
                message.replyToSenderUserId = original.senderId
                message.replyToPreview = FormattedString(text: original.content.textPreview)
            }
            state.messages[chatId, default: []].append(message)
            state.chats[chatId]?.lastMessage = message
            state.chats[chatId]?.order = Int64(message.date.timeIntervalSince1970)
            return message
        }
        emit(.newMessage(message))
        return message
    }

    // MARK: Changing and reading

    func deleteMessage(chatId: Int64, messageId: Int64) async throws {
        state.withLock { $0.messages[chatId]?.removeAll { $0.id == messageId } }
        emit(.deleteMessages(chatId: chatId, messageIds: [messageId]))
    }

    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo {
        let edited = state.withLock { state -> MessageInfo? in
            guard let index = state.messages[chatId]?.firstIndex(where: { $0.id == messageId }) else { return nil }
            state.messages[chatId]?[index].content = .text(FormattedString(text: newText))
            return state.messages[chatId]?[index]
        }
        guard let edited else { throw TDError.unexpectedResponse }
        emit(.messageContentChanged(chatId: chatId, messageId: messageId, content: edited.content))
        return edited
    }

    func markAsRead(chatId: Int64, messageId: Int64) async throws {
        try await markAsRead(chatId: chatId, messageIds: [messageId])
    }

    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws {
        guard let chat = state.withLock({ $0.chats[chatId] }), chat.unreadCount > 0 else { return }
        if let updated = update(chatId, { $0.unreadCount = 0 }) {
            emit(.chatUpdated(updated))
        }
    }

    func openMessageContent(chatId: Int64, messageId: Int64) async {}

    // MARK: Reactions

    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {}

    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {}

    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String] {
        QuickReactionPreference.options
    }

    // MARK: Channels and bots

    /// No ads in demo mode.
    func getChatSponsoredMessages(chatId: Int64) async throws -> SponsoredMessageBatch {
        SponsoredMessageBatch(messages: [], messagesBetween: 0)
    }

    func viewSponsoredMessage(chatId: Int64, messageId: Int64) async throws {}

    func clickSponsoredMessage(chatId: Int64, messageId: Int64) async throws {}

    func reportSponsoredMessage(chatId: Int64, messageId: Int64, optionId: Data) async throws -> SponsoredReportResult {
        .failed
    }

    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        nil
    }

    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo] {
        []
    }
}
#endif
