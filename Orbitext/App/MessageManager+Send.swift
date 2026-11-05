import Foundation
import os

extension MessageManager {
    enum SendOutcome: Equatable {
        case sent
        case queued
        case failed
        case cancelled

        /// The text is with TDLib or the offline queue, so a draft can go.
        var wasAccepted: Bool { self == .sent || self == .queued }
    }

    /// Only a message TDLib never received belongs in the offline queue: a
    /// running client queues offline messages itself, so its error means the
    /// message was refused (retrying cannot help) or, on a timeout or an
    /// abandoned request, possibly accepted already (a retry could send it twice).
    static func isRetryableLater(_ error: Error) -> Bool {
        if case TelegramServiceError.notStarted = error { return true }
        guard let tdError = error as? TDError else { return false }
        if case .clientClosed = tdError { return true }
        return tdError.floodWaitSeconds != nil
    }

    func loadMessages(chatId: Int64, fromMessageId: Int64 = 0, limit: Int = AppConstants.Message.defaultLoadLimit) async -> [MessageInfo] {
        await fetch(default: []) {
            try await service.getMessages(chatId: chatId, fromMessageId: fromMessageId, limit: limit)
        }
    }

    @discardableResult
    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64? = nil, opensPrivateChat: Bool = false) async -> SendOutcome {
        if opensPrivateChat {
            // Never queue before the chat exists: the queue would retry into "Chat not found".
            do {
                try await service.createPrivateChat(userId: chatId)
            } catch is CancellationError {
                return .cancelled
            } catch {
                errorPresenter?.show(error)
                HapticManager.error()
                return .failed
            }
        }
        return await sendTrackedMessage(chatId: chatId, text: text, replyToMessageId: replyToMessageId).outcome
    }

    /// Same as `sendMessage`, plus the pending message TDLib accepted, so a
    /// background caller can wait for its server result.
    func sendTrackedMessage(
        chatId: Int64,
        text: String,
        replyToMessageId: Int64? = nil
    ) async -> (outcome: SendOutcome, accepted: MessageInfo?) {
        do {
            let accepted = try await sendTextMessage(chatId: chatId, text: text, replyToMessageId: replyToMessageId)
            HapticManager.messageSent()
            return (.sent, accepted)
        } catch is CancellationError {
            return (.cancelled, nil)
        } catch TDError.unexpectedResponse {
            // TDLib answered with the pending message; only parsing it failed.
            HapticManager.messageSent()
            return (.sent, nil)
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            guard Self.isRetryableLater(error) else { return (.failed, nil) }
            messageQueue.enqueue(chatId: chatId, text: text, replyToMessageId: replyToMessageId)
            return (.queued, nil)
        }
    }

    @discardableResult
    func sendVoice(chatId: Int64, data: Data, duration: Int) async -> Bool {
        do {
            let _ = try await service.sendVoice(chatId: chatId, data: data, duration: duration)
            HapticManager.messageSent()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return false
        }
    }

    func sendTextMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        try await service.sendMessage(chatId: chatId, text: text, replyToMessageId: replyToMessageId)
    }

    @discardableResult
    func deleteMessage(chatId: Int64, messageId: Int64) async -> Bool {
        do {
            try await service.deleteMessage(chatId: chatId, messageId: messageId)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorPresenter?.show(error)
            return false
        }
    }

    func editMessage(chatId: Int64, messageId: Int64, newText: String) async -> MessageInfo? {
        await fetch(default: nil) {
            try await service.editMessage(chatId: chatId, messageId: messageId, newText: newText)
        }
    }

    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async {
        await perform(haptic: HapticManager.messageSent) {
            try await service.forwardMessage(fromChatId: fromChatId, messageId: messageId, toChatId: toChatId)
        }
    }

    // MARK: - Reactions

    @discardableResult
    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async -> Bool {
        let normalizedEmoji = emoji.normalizedReactionEmoji
        do {
            try await service.setReaction(chatId: chatId, messageId: messageId, emoji: normalizedEmoji)
            HapticManager.reactionAdded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            let nsError = error as NSError
            let message = nsError.localizedDescription.lowercased()
            if message.contains("reaction isn't available") || message.contains("reaction is not available") {
                return false
            }
            // TDLib returns 400 "Message not found" when the
            // user reacts on a still-in-flight outgoing message (temp id).
            // The optimistic UI in onReact will revert on !succeeded so
            // there is already a visual cue; do NOT also surface a toast.
            if message.contains("message not found") {
                return false
            }
            errorPresenter?.show(error)
            return false
        }
    }

    func loadAvailableReactions(chatId: Int64, messageId: Int64) async -> [String] {
        let available: [String]
        do {
            available = try await service.getAvailableMessageReactions(chatId: chatId, messageId: messageId)
        } catch {
            Logger.tdlib.warning("getAvailableMessageReactions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var ordered: [String] = []
        for reaction in available.map(\.normalizedReactionEmoji) where !reaction.isEmpty {
            if !ordered.contains(reaction) {
                ordered.append(reaction)
            }
        }
        return ordered
    }

    @discardableResult
    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async -> Bool {
        let normalizedEmoji = emoji.normalizedReactionEmoji
        do {
            try await service.removeReaction(chatId: chatId, messageId: messageId, emoji: normalizedEmoji)
            return true
        } catch is CancellationError {
            return false
        } catch {
            // Same temp-id race as setReaction - silently
            // fail when the server doesn't know the message id yet.
            let message = (error as NSError).localizedDescription.lowercased()
            if message.contains("message not found") {
                return false
            }
            errorPresenter?.show(error)
            return false
        }
    }

    // MARK: - Typing

    func sendTyping(chatId: Int64) async {
        do {
            try await service.sendTyping(chatId: chatId)
        } catch {
            Logger.tdlib.debug("sendTyping failed for chat=\(chatId): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Search

    func searchMessages(query: String, chatId: Int64? = nil) async -> [MessageInfo] {
        await fetch(default: [], showError: false) {
            try await service.searchMessages(query: query, chatId: chatId)
        }
    }

    // MARK: - Contacts

    func loadContacts(forceRefresh: Bool = false) async -> [ContactInfo] {
        if !forceRefresh, let cachedContacts, !cachedContacts.isEmpty {
            return cachedContacts
        }

        let fresh = await fetch(default: cachedContacts ?? []) {
            try await service.getContacts()
        }
        cachedContacts = fresh
        contactListCache.save(fresh)
        return fresh
    }

    func loadContact(userId: Int64) async -> ContactInfo? {
        await fetch(default: nil, showError: false) {
            try await service.getContact(userId: userId)
        }
    }

    func searchContacts(query: String) async -> [ContactInfo] {
        await fetch(default: [], showError: false) {
            try await service.searchContacts(query: query)
        }
    }

    func getMe() async -> ContactInfo? {
        do {
            return try await service.getMe()
        } catch {
            Logger.tdlib.warning("getMe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func getGroupInfo(chatId: Int64) async -> GroupInfo? {
        await fetch(default: nil, showError: false) {
            try await service.getGroupInfo(chatId: chatId)
        }
    }
}
