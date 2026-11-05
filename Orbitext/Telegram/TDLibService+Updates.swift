import Foundation
import os

// MARK: - TDLib update dispatch

extension TDLibService {
    func handleUpdate(_ update: [String: Any]) {
        guard let type = update["@type"] as? String else { return }
        releaseVoiceUploads(after: update, type: type)

        // Typed-first dispatch: the update types in scripts/codegen-roots.txt
        // are consumed by Update+Mapping, which returns true for each of them.
        // Everything else (complex updates that need dict-based model
        // construction) falls through to the switch below.
        if handleUpdateTyped(update) { return }

        switch type {
        case "updateAuthorizationState":
            guard let state = update["authorization_state"] as? [String: Any] else { return }
            handleAuthUpdate(state)

        case "updateNewChat":
            handleNewChatUpdate(update)

        case "updateNewMessage":
            handleNewMessageUpdate(update)

        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            handleMessageSendCompletedUpdate(update)

        case "updateChatLastMessage":
            handleChatLastMessageUpdate(update)

        case "updateChatUnreadReactionCount":
            handleChatUnreadReactionCountUpdate(update)

        case "updateChatDraftMessage":
            handleChatDraftMessageUpdate(update)

        case "updateChatAction":
            handleChatActionUpdate(update)

        case "updateActiveNotifications":
            handleActiveNotificationsUpdate(update)

        case "updateNotificationGroup":
            handleNotificationGroupUpdate(update)

        case "updateUser":
            handleUserUpdate(update)

        case "updateChatFolders":
            handleChatFoldersUpdate(update)

        case "updateChatReplyMarkup":
            handleChatReplyMarkupUpdate(update)

        default:
            break
        }
    }

    // MARK: - Individual Update Handlers

    private func handleNewChatUpdate(_ update: [String: Any]) {
        guard let chatData = update["chat"] as? [String: Any] else { return }
        let chat = parseChatInfo(chatData)
        guard chat.id != 0 else { return }
        chatCache.set(chat.id, chat)
        // Every announced chat reaches the repository, listed or not: it
        // looks chats up by id, and the positions say which lists hold it.
        emit(.chatPositionChanged(.init(
            chat: chat,
            positions: parseChatPositions(chatData["positions"]) ?? [],
            source: .newChat
        )))
    }

    private func handleNewMessageUpdate(_ update: [String: Any]) {
        guard let rawMsg = update["message"] as? [String: Any],
              let msg = parseMessageInfo(rawMsg) else { return }
        emit(.newMessage(msg))
    }

    private func handleMessageSendCompletedUpdate(_ update: [String: Any]) {
        let oldMessageId = toInt64(update["old_message_id"])
        guard oldMessageId != 0,
              let rawMessage = update["message"] as? [String: Any] else { return }
        let typedMessage = decodeMessageDict(rawMessage)
        guard var message = MessageInfo(tdApi: typedMessage, service: self), message.chatId != 0 else { return }
        message.isSending = false
        if update["@type"] as? String == "updateMessageSendFailed" {
            let error = (update["error"] as? [String: Any]).map { TDApi.decodeError($0) }
            message.sendingFailure = message.sendingFailure ?? MessageSendFailure(tdApi: error)
        } else {
            message.sendingFailure = nil
        }
        replyMessageCache.remove(MessageKey(chatId: message.chatId, messageId: oldMessageId))
        replyMessageCache.set(MessageKey(chatId: message.chatId, messageId: message.id), typedMessage)
        _ = chatCache.mutate(message.chatId) { chat in
            if chat.lastMessage?.id == oldMessageId || chat.lastMessage?.id == message.id {
                chat.lastMessage = message
            }
        }
        emit(.messageSendCompleted(oldMessageId: oldMessageId, message: message))
    }

    private func handleChatLastMessageUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        // Parse outside the cache lock: parseMessageInfo may read from chatCache/userCache.
        let parsedLastMessage: MessageInfo?
        if let rawMsg = update["last_message"] as? [String: Any] {
            parsedLastMessage = parseMessageInfo(rawMsg)
        } else {
            parsedLastMessage = nil
        }
        let positions = parseChatPositions(update["positions"])
        if let chat = chatCache.mutate(chatId, { chat in
            chat.lastMessage = parsedLastMessage
            if let positions { applyMainPosition(positions, to: &chat) }
        }) {
            emitChatFieldsAndPositions(chat, positions: positions)
        }
    }

    private func handleChatUnreadReactionCountUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        let count = update["unread_reaction_count"] as? Int ?? 0
        _ = chatCache.mutate(chatId) { $0.reactionCount = count }
        emit(.chatReactionCountChanged(chatId: chatId, count: count))
    }

    private func handleChatDraftMessageUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        let positions = parseChatPositions(update["positions"])
        if let chat = chatCache.mutate(chatId, { chat in
            chat.draftMessage = extractDraftText(from: update)
            if let positions { applyMainPosition(positions, to: &chat) }
        }) {
            emitChatFieldsAndPositions(chat, positions: positions)
        }
    }

    private func applyMainPosition(_ positions: [ChatListPosition], to chat: inout ChatInfo) {
        let main = positions.first { $0.list == .main }
        chat.order = main?.order ?? 0
        chat.isPinned = main?.isPinned ?? false
    }

    private func emitChatFieldsAndPositions(_ chat: ChatInfo, positions: [ChatListPosition]?) {
        guard let positions else {
            emit(.chatUpdated(chat))
            return
        }
        // The whole vector after the change: a list missing from it has lost
        // the chat, but only once this session knew the chat was in it. The
        // repository owns that distinction.
        emit(.chatPositionChanged(.init(chat: chat, positions: positions, source: .positionsReplacement)))
    }

    private func handleChatActionUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        guard let action = update["action"] as? [String: Any],
              let actionType = action["@type"] as? String else { return }

        let senderIdDict = update["sender_id"] as? [String: Any]
        let senderType = senderIdDict?["@type"] as? String
        let senderId: Int64
        if senderType == "messageSenderChat" {
            senderId = toInt64(senderIdDict?["chat_id"])
        } else {
            senderId = toInt64(senderIdDict?["user_id"])
        }
        guard senderId != 0 else { return }
        let name: String
        if senderType == "messageSenderChat" {
            name = chatCache.get(senderId)?.title ?? "Chat"
        } else {
            name = userCache.get(senderId)?.firstName ?? "Someone"
        }

        guard let snapshot = chatActions.withLock({
            $0.apply(chatId: chatId, senderId: senderId, name: name, actionType: actionType)
        }) else { return }

        emit(.chatAction(chatId: chatId, names: snapshot.names, kind: snapshot.kind))
    }

    private func handleActiveNotificationsUpdate(_ update: [String: Any]) {
        guard let groups = normalizeArray(update["groups"]) else { return }
        for group in groups.compactMap({ normalizeDictionary($0) }) {
            let chatId = toInt64(group["chat_id"])
            let groupType = normalizeDictionary(group["type"])
            let notifications = normalizeArray(group["notifications"]) ?? []
            emitRemoteNotifications(from: notifications, chatId: chatId, groupType: groupType)
        }
    }

    private func handleNotificationGroupUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        let groupType = normalizeDictionary(update["type"])
        let notifications = normalizeArray(update["added_notifications"]) ?? []
        emitRemoteNotifications(from: notifications, chatId: chatId, groupType: groupType)
    }

    private func emitRemoteNotifications(from rawNotifications: [Any], chatId: Int64, groupType: [String: Any]?) {
        guard isMessageNotificationGroup(groupType) else { return }

        for rawNotification in rawNotifications {
            guard let notification = normalizeDictionary(rawNotification),
                  let info = parseRemoteNotificationInfo(notification, chatId: chatId) else {
                continue
            }
            emit(.remoteNotification(info))
        }
    }

    private func isMessageNotificationGroup(_ groupType: [String: Any]?) -> Bool {
        switch groupType?["@type"] as? String {
        case "notificationGroupTypeMessages", "notificationGroupTypeMentions":
            return true
        default:
            return false
        }
    }

    private func parseRemoteNotificationInfo(_ notification: [String: Any], chatId: Int64) -> RemoteNotificationInfo? {
        let isSilent = notification["is_silent"] as? Bool ?? false
        guard let type = normalizeDictionary(notification["type"]),
              let typeName = type["@type"] as? String else {
            return nil
        }

        switch typeName {
        case "notificationTypeNewMessage":
            guard let rawMessage = normalizeDictionary(type["message"]),
                  let message = parseMessageInfo(rawMessage),
                  !message.isOutgoing,
                  message.content.isNotifiable else {
                return nil
            }

            let preview: String
            if type["show_preview"] as? Bool == false {
                preview = L10n.string("New message")
            } else {
                // The system reads notification text aloud as written.
                preview = message.content.textPreview.speakingSpoilerMasks
            }

            let chatTitle = chatCache.get(chatId)?.title ?? (message.senderName.isEmpty ? "Telegram" : message.senderName)
            let senderName = message.senderName.isEmpty ? chatTitle : message.senderName
            return RemoteNotificationInfo(
                chatId: chatId,
                chatTitle: chatTitle,
                senderName: senderName,
                preview: preview,
                notificationKey: message.viewID,
                playSound: !isSilent
            )

        case "notificationTypeNewPushMessage":
            let messageId = toInt64(type["message_id"])
            guard !(type["is_outgoing"] as? Bool ?? false) else { return nil }

            let senderName = (type["sender_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = pushMessagePreview(from: normalizeDictionary(type["content"]))
            let validSender = (senderName?.isEmpty == false) ? senderName : nil
            let chatTitle = chatCache.get(chatId)?.title ?? validSender ?? "Telegram"

            return RemoteNotificationInfo(
                chatId: chatId,
                chatTitle: chatTitle,
                senderName: validSender ?? chatTitle,
                preview: preview,
                // Same key as MessageInfo.viewID: the message is notified only
                // once whether the push or the downloaded message arrives first.
                notificationKey: "\(chatId):\(messageId)",
                playSound: !isSilent
            )

        default:
            return nil
        }
    }

    private func pushMessagePreview(from content: [String: Any]?) -> String {
        guard let content,
              let type = content["@type"] as? String else {
            return L10n.string("New message")
        }

        let caption = (content["caption"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch type {
        case "pushMessageContentText":
            let text = (content["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? L10n.string("New message") : text
        case "pushMessageContentPhoto":
            return caption.isEmpty ? L10n.string("Photo") : caption
        case "pushMessageContentVideo":
            return caption.isEmpty ? L10n.string("Video") : caption
        case "pushMessageContentAnimation":
            return caption.isEmpty ? L10n.string("GIF") : caption
        case "pushMessageContentSticker":
            let emoji = (content["emoji"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return emoji.isEmpty ? L10n.string("Sticker") : "\(emoji) \(L10n.string("Sticker"))"
        case "pushMessageContentVoiceNote":
            return L10n.string("Voice")
        case "pushMessageContentVideoNote":
            return L10n.string("Video message")
        case "pushMessageContentAudio":
            return L10n.string("Audio")
        case "pushMessageContentDocument":
            return L10n.string("Document")
        case "pushMessageContentLocation":
            return L10n.string("Location")
        case "pushMessageContentPoll":
            let question = (content["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return question.isEmpty ? L10n.string("Poll") : "📊 \(question)"
        case "pushMessageContentContact":
            return L10n.string("Contact")
        default:
            return L10n.string("New message")
        }
    }

    private func handleUserUpdate(_ update: [String: Any]) {
        if let rawUser = update["user"] as? [String: Any] {
            let user = UserInfo(tdApi: TDApi.decodeUser(rawUser))
            userCache.set(user.id, user)
            // Update online status for private chats (chatId == userId)
            let isOnline = user.status.isOnline
            if let chat = chatCache.mutate(user.id, { $0.isOnline = isOnline }) {
                emit(.chatUpdated(chat))
            }
        }
    }

    private func handleChatFoldersUpdate(_ update: [String: Any]) {
        if let rawFolders = update["chat_folders"] as? [[String: Any]] {
            let folders = rawFolders.map { info in
                ChatFolder(
                    id: toInt64(info["id"]),
                    title: parseFolderTitle(info),
                    iconName: (info["icon"] as? [String: Any])?["name"] as? String ?? "folder",
                    chatIds: []
                )
            }
            emit(.foldersUpdated(folders))
        }
    }
}
