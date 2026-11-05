import Foundation
import os

// MARK: - Bot keyboards, callback queries and command menus

extension TDLibService {
    /// Presses an inline callback button. TDLib rewrites the server's
    /// BOT_RESPONSE_TIMEOUT to error 502, which is reported as
    /// BotInteractionError.botNotResponding so the UI can show a neutral
    /// notice instead of the raw English TDLib message.
    func getCallbackQueryAnswer(chatId: Int64, messageId: Int64, data: String) async throws -> BotCallbackAnswer {
        do {
            let result = try await throttledSend([
                "@type": "getCallbackQueryAnswer",
                "chat_id": chatId,
                "message_id": messageId,
                "payload": ["@type": "callbackQueryPayloadData", "data": data] as [String: Any]
            ])
            return BotCallbackAnswer(tdApiDict: result)
        } catch TDError.api(code: 502, message: _) {
            throw BotInteractionError.botNotResponding
        }
    }

    /// The message carrying the chat's active reply keyboard, or nil when
    /// the chat has none. Both reads are served from TDLib's local database.
    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        let chat = try await dedupedLocalSend(
            ["@type": "getChat", "chat_id": chatId],
            key: "getChat:\(chatId)"
        )
        let messageId = toInt64(chat["reply_markup_message_id"])
        guard messageId != 0 else { return nil }
        let message = try await dedupedLocalSend(
            ["@type": "getMessage", "chat_id": chatId, "message_id": messageId],
            key: "getMessage:\(chatId):\(messageId)"
        )
        return parseMessageInfo(message)
    }

    /// TDLib requires this after a one-time keyboard or a force-reply
    /// request has been used.
    func deleteChatReplyMarkup(chatId: Int64, messageId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "deleteChatReplyMarkup",
            "chat_id": chatId,
            "message_id": messageId
        ])
    }

    /// Command menu of the bot in a private chat, or of every bot in a
    /// group. Other chats (users, channels, secret chats) have none.
    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo] {
        let chat = try await dedupedLocalSend(
            ["@type": "getChat", "chat_id": chatId],
            key: "getChat:\(chatId)"
        )
        guard let type = normalizeDictionary(chat["type"]) else { return [] }
        switch type["@type"] as? String {
        case "chatTypePrivate":
            let userId = toInt64(type["user_id"])
            guard userId != 0, try await cachedOrFetchUser(userId: userId).isBot else {
                return []
            }
            let fullInfo = try await throttledSend(["@type": "getUserFullInfo", "user_id": userId])
            return BotCommandInfo.list(userFullInfo: fullInfo)
        case "chatTypeBasicGroup":
            let fullInfo = try await throttledSend([
                "@type": "getBasicGroupFullInfo",
                "basic_group_id": toInt64(type["basic_group_id"])
            ])
            return await groupBotCommands(fullInfo)
        case "chatTypeSupergroup":
            guard type["is_channel"] as? Bool != true else { return [] }
            let fullInfo = try await throttledSend([
                "@type": "getSupergroupFullInfo",
                "supergroup_id": toInt64(type["supergroup_id"])
            ])
            return await groupBotCommands(fullInfo)
        default:
            return []
        }
    }

    /// Shares the account's own contact card, as Telegram clients do for a
    /// keyboardButtonTypeRequestPhoneNumber button.
    func sharePhoneNumber(chatId: Int64) async throws -> MessageInfo {
        let me = try await throttledSend(["@type": "getMe"])
        let phone = me["phone_number"] as? String ?? ""
        guard !phone.isEmpty else { throw BotInteractionError.unsupported }
        let result = try await throttledSend([
            "@type": "sendMessage",
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageContact",
                "contact": [
                    "@type": "contact",
                    "phone_number": phone,
                    "first_name": me["first_name"] as? String ?? "",
                    "last_name": me["last_name"] as? String ?? "",
                    "vcard": "",
                    "user_id": toInt64(me["id"])
                ] as [String: Any]
            ] as [String: Any]
        ])
        guard let message = parseMessageInfo(result) else { throw TDError.unexpectedResponse }
        return message
    }

    /// updateChatReplyMarkup. TDLib sends the whole message (null when the
    /// keyboard is gone); read from the raw dict, the generated bindings do
    /// not decode this update.
    func handleChatReplyMarkupUpdate(_ update: [String: Any]) {
        let chatId = toInt64(update["chat_id"])
        guard chatId != 0 else { return }
        let message = normalizeDictionary(update["reply_markup_message"]).flatMap { parseMessageInfo($0) }
        emit(.chatReplyMarkupChanged(chatId: chatId, message: message))
    }

    /// Group commands are addressed as /command@bot, so each bot's username
    /// is resolved first; a bot whose user cannot be loaded keeps bare
    /// commands rather than hiding them.
    private func groupBotCommands(_ fullInfo: [String: Any]) async -> [BotCommandInfo] {
        var usernames: [Int64: String] = [:]
        for entry in ReplyMarkup.array(fullInfo["bot_commands"]) {
            let botUserId = toInt64(ReplyMarkup.dictionary(entry)?["bot_user_id"])
            guard botUserId != 0, usernames[botUserId] == nil else { continue }
            do {
                let user = try await cachedOrFetchUser(userId: botUserId)
                usernames[botUserId] = user.activeUsername
            } catch {
                Logger.tdlib.debug("bot username lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return BotCommandInfo.list(groupFullInfo: fullInfo, resolveUsername: { usernames[$0] })
    }
}
