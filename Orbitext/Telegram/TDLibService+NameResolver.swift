import Foundation
import os

// MARK: - Name resolution for forwards/replies, and parseMessageInfo

extension TDLibService {
    /// The one place a standalone message dict (a received message, a
    /// `getMessage` answer, the message of a send-completed update) becomes a
    /// `TDApi.Message`. Shape fix-ups for message JSON belong here. A chat's
    /// last message is decoded inside `TDApi.decodeChat` instead.
    func decodeMessageDict(_ dict: [String: Any]) -> TDApi.Message {
        TDApi.decodeMessage(normalizeContent(dict))
    }

    /// The boundary between TDLib JSON and the message mapping: decodes the
    /// dict once into the generated `TDApi.Message` and maps that. Nil when
    /// the dict carries no message id.
    func parseMessageInfo(_ dict: [String: Any]) -> MessageInfo? {
        let typedMsg = decodeMessageDict(dict)
        guard typedMsg.id != 0 else { return nil }
        return MessageInfo(tdApi: typedMsg, service: self)
    }

    // MARK: - MessageOrigin

    /// The origin of a forward as the generated type reports it, named from
    /// the user and chat caches (see `MessageOrigin.init(tdApi:...)`).
    func messageOrigin(from origin: TDApi.MessageOrigin) -> MessageOrigin? {
        MessageOrigin(
            tdApi: origin,
            resolveUserName: { [userCache] userId in
                userCache.get(userId)?.displayName
            },
            resolveChatTitle: { [chatCache] chatId in
                chatCache.get(chatId)?.title
            }
        )
    }

    // MARK: - Resolve Forward & Reply Names

    /// Per-message patch produced concurrently; applied serially after the
    /// task group finishes so the public `messages` array does not need
    /// shared-state synchronization across child tasks.
    struct MessageNamePatch {
        var senderName: String?
        var senderResolved: Bool?
        var forwardedOrigin: MessageOrigin??
        var replyToSenderName: String??
        var replyToSenderResolved: Bool?
        var replyToPreview: FormattedString??
    }

    struct MessageNameResolutionContext {
        var messageMap: [MessageKey: MessageInfo]
        var userNames: [Int64: String]
        var replyMessages: [MessageKey: TDApi.Message]
    }

    func resolveMessageNames(_ messages: inout [MessageInfo]) async {
        let context = await makeMessageNameResolutionContext(for: messages)

        // Fan out pure patch computation per message after the shared
        // context has collapsed repeated local TDLib lookups.
        let patches: [Int: MessageNamePatch] = await withTaskGroup(
            of: (Int, MessageNamePatch).self
        ) { group in
            for i in messages.indices {
                let snapshot = messages[i]
                group.addTask {
                    let patch = await self.computeNamePatch(
                        for: snapshot,
                        context: context
                    )
                    return (i, patch)
                }
            }
            var result: [Int: MessageNamePatch] = [:]
            for await (index, patch) in group {
                result[index] = patch
            }
            return result
        }

        for i in messages.indices {
            guard let patch = patches[i] else { continue }
            if let v = patch.senderName { messages[i].senderName = v }
            if let v = patch.senderResolved { messages[i].senderResolved = v }
            if let v = patch.forwardedOrigin { messages[i].forwardedOrigin = v }
            if let v = patch.replyToSenderName { messages[i].replyToSenderName = v }
            if let v = patch.replyToSenderResolved { messages[i].replyToSenderResolved = v }
            if let v = patch.replyToPreview { messages[i].replyToPreview = v }
        }
    }

    /// Build a per-page lookup context so repeated unresolved users and
    /// repeated reply targets cost one local TDLib read each instead of one
    /// read per visible message.
    private func makeMessageNameResolutionContext(for messages: [MessageInfo]) async -> MessageNameResolutionContext {
        let messageMap = Dictionary(messages.map { (MessageKey(chatId: $0.chatId, messageId: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let replyMessages = await prefetchReplyMessages(for: messages, messageMap: messageMap)

        var userIds = Set<Int64>()
        for message in messages {
            if !message.senderResolved && message.senderId != 0 {
                userIds.insert(message.senderId)
            }
            if case .user(let userId, let name) = message.forwardedOrigin,
               name.hasPrefix("#user:"),
               userId != 0 {
                userIds.insert(userId)
            }
            if let replyId = message.replyToMessageId,
               let original = messageMap[MessageKey(chatId: message.chatId, messageId: replyId)],
               !original.senderResolved,
               original.senderId != 0 {
                userIds.insert(original.senderId)
            }
            if !message.replyToSenderResolved,
               let replySenderUserId = message.replyToSenderUserId,
               replySenderUserId != 0 {
                userIds.insert(replySenderUserId)
            }
        }

        for reply in replyMessages.values {
            guard case .messageSenderUser(let sender)? = reply.senderId, sender.userId != 0 else { continue }
            userIds.insert(sender.userId)
        }

        let userNames = await prefetchUserNames(userIds)
        return MessageNameResolutionContext(
            messageMap: messageMap,
            userNames: userNames,
            replyMessages: replyMessages
        )
    }

    private func prefetchReplyMessages(
        for messages: [MessageInfo],
        messageMap: [MessageKey: MessageInfo]
    ) async -> [MessageKey: TDApi.Message] {
        let replyKeys = Set(
            messages.compactMap { message -> MessageKey? in
                guard let replyId = message.replyToMessageId else { return nil }
                let key = MessageKey(chatId: message.chatId, messageId: replyId)
                let original = messageMap[key]
                let needsPreview = message.replyToPreview == nil && original == nil
                let needsSenderMessage = !message.replyToSenderResolved
                    && message.replyToSenderUserId == nil
                    && !(original?.senderResolved ?? false)
                return needsPreview || needsSenderMessage ? key : nil
            }
        )
        guard !replyKeys.isEmpty else { return [:] }

        return await withTaskGroup(of: (MessageKey, TDApi.Message?).self) { group in
            for key in replyKeys {
                group.addTask {
                    if let cached = self.replyMessageCache.get(key) {
                        return (key, cached)
                    }
                    do {
                        let raw = try await self.dedupedLocalSend([
                            "@type": "getMessage",
                            "chat_id": key.chatId,
                            "message_id": key.messageId
                        ], key: "getMessage:\(key.chatId):\(key.messageId)")
                        let message = self.decodeMessageDict(raw)
                        self.replyMessageCache.set(key, message)
                        return (key, message)
                    } catch {
                        Logger.tdlib.debug("  getMessage failed: \(error.localizedDescription)")
                        return (key, nil)
                    }
                }
            }

            var result: [MessageKey: TDApi.Message] = [:]
            for await (key, message) in group {
                if let message { result[key] = message }
            }
            return result
        }
    }

    private func prefetchUserNames(_ userIds: Set<Int64>) async -> [Int64: String] {
        guard !userIds.isEmpty else { return [:] }

        return await withTaskGroup(of: (Int64, String?).self) { group in
            for userId in userIds {
                group.addTask {
                    do {
                        let user = try await self.cachedOrFetchUser(userId: userId)
                        return (userId, user.displayName)
                    } catch {
                        return (userId, nil)
                    }
                }
            }

            var result: [Int64: String] = [:]
            for await (userId, name) in group {
                if let name { result[userId] = name }
            }
            return result
        }
    }

    /// Compute resolution updates for a single message without mutating
    /// shared state on the caller side. Caches (chatCache/userCache) are
    /// thread-safe via NSLock, so concurrent reads/writes from sibling
    /// tasks are safe; the returned patch is then applied by the caller.
    private func computeNamePatch(
        for snapshot: MessageInfo,
        context: MessageNameResolutionContext
    ) async -> MessageNamePatch {
        var patch = MessageNamePatch()

        // Sender placeholder resolution.
        if !snapshot.senderResolved && snapshot.senderId != 0 {
            if let name = context.userNames[snapshot.senderId] {
                patch.senderName = name
                patch.senderResolved = true
            }
        }

        // Forwarded user-origin with unresolved name (the parser stores
        // `#user:ID` in the display name when the user was not yet in
        // cache). Re-fetch through getUser and patch the typed origin.
        if case .user(let userId, let name) = snapshot.forwardedOrigin,
           name.hasPrefix("#user:"), userId != 0 {
            let final = context.userNames[userId] ?? L10n.string("User")
            patch.forwardedOrigin = .some(.user(userId: userId, name: final))
        }

        guard let replyId = snapshot.replyToMessageId else { return patch }
        let replyKey = MessageKey(chatId: snapshot.chatId, messageId: replyId)

        // Preview from local messages.
        if snapshot.replyToPreview == nil, let original = context.messageMap[replyKey] {
            patch.replyToPreview = .some(FormattedString(text: original.content.textPreview))
        }

        if !snapshot.replyToSenderResolved,
           let original = context.messageMap[replyKey],
           original.senderResolved {
            patch.replyToSenderName = .some(original.senderName)
            patch.replyToSenderResolved = true
            return patch
        }

        if !snapshot.replyToSenderResolved,
           let replySenderUserId = snapshot.replyToSenderUserId,
           replySenderUserId != 0 {
            if let name = context.userNames[replySenderUserId] {
                patch.replyToSenderName = .some(name)
                patch.replyToSenderResolved = true
                if snapshot.replyToPreview != nil || patch.replyToPreview != nil {
                    return patch
                }
            } else {
                patch.replyToSenderName = .some(L10n.string("User"))
            }
        }

        // Re-fetch only when our flag says reply sender wasn't resolved.
        if !snapshot.replyToSenderResolved || (snapshot.replyToPreview == nil && patch.replyToPreview == nil) {
            if let reply = context.replyMessages[replyKey] {
                if !snapshot.replyToSenderResolved, patch.replyToSenderResolved != true {
                    switch reply.senderId {
                    case .messageSenderUser(let sender)?:
                        if let name = context.userNames[sender.userId] {
                            patch.replyToSenderName = .some(name)
                            patch.replyToSenderResolved = true
                        } else {
                            patch.replyToSenderName = .some(L10n.string("User"))
                        }
                    case .messageSenderChat(let sender)?:
                        patch.replyToSenderName = .some(chatCache.get(sender.chatId)?.title ?? L10n.string("Chat"))
                        patch.replyToSenderResolved = true
                    case .unknown?, nil:
                        break
                    }
                }

                if snapshot.replyToPreview == nil && patch.replyToPreview == nil {
                    let content = reply.content.map(MessageContent.init(tdApi:)) ?? .unsupported("unknown")
                    patch.replyToPreview = .some(FormattedString(text: content.textPreview))
                }
            } else if let original = context.messageMap[replyKey] {
                patch.replyToSenderName = .some(original.senderName)
                patch.replyToSenderResolved = original.senderResolved
                if snapshot.replyToPreview == nil && patch.replyToPreview == nil {
                    patch.replyToPreview = .some(FormattedString(text: original.content.textPreview))
                }
            }
        }

        return patch
    }

    func resolveUserName(senderId: Int64) async -> String? {
        guard senderId != 0 else { return nil }
        do {
            return try await cachedOrFetchUser(userId: senderId).displayName
        } catch {
            return nil
        }
    }
}
