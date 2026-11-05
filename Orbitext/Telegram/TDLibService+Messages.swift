import Foundation
import os

// MARK: - Message CRUD and search

extension TDLibService {
    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] {
        let result = try await throttledSend([
            "@type": "getChatHistory",
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": 0,
            "limit": limit,
            "only_local": false
        ])

        guard let messages = result["messages"] as? [[String: Any]] else {
            return []
        }

        var parsed = messages.compactMap { parseMessageInfo($0) }
        let mismatched = parsed.filter { $0.chatId != chatId }
        if !mismatched.isEmpty {
            let foreignChatIds = mismatched.map { String($0.chatId) }.joined(separator: ",")
            Logger.tdlib.error("getMessages(chatId=\(chatId, privacy: .public)) returned \(mismatched.count) foreign messages from chats [\(foreignChatIds, privacy: .public)]")
        }
        parsed.removeAll { $0.chatId != chatId }
        await resolveMessageNames(&parsed)
        return parsed
    }

    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        var request: [String: Any] = [
            "@type": "sendMessage",
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": text
                ]
            ]
        ]

        if let replyId = replyToMessageId, replyId != 0 {
            request["reply_to"] = [
                "@type": "inputMessageReplyToMessage",
                "message_id": replyId
            ]
        }

        let result = try await throttledSend(request)
        guard let msg = parseMessageInfo(result) else {
            throw TDError.unexpectedResponse
        }
        return msg
    }

    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo {
        let uploadURL = try prepareVoiceUploadFile(data)

        let result: [String: Any]
        do {
            result = try await throttledSend([
                "@type": "sendMessage",
                "chat_id": chatId,
                "input_message_content": [
                    "@type": "inputMessageVoiceNote",
                    "voice_note": [
                        "@type": "inputFileLocal",
                        "path": uploadURL.path
                    ] as [String: Any],
                    "duration": duration
                ] as [String: Any],
            ])
        } catch {
            removeVoiceUploadFile(uploadURL)
            throw error
        }

        guard let msg = parseMessageInfo(result) else {
            throw TDError.unexpectedResponse
        }
        bindVoiceUpload(uploadURL, to: msg)
        return msg
    }

    func deleteMessage(chatId: Int64, messageId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "deleteMessages",
            "chat_id": chatId,
            "message_ids": [messageId],
            "revoke": true
        ])
    }

    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo {
        let result = try await throttledSend([
            "@type": "editMessageText",
            "chat_id": chatId,
            "message_id": messageId,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": newText
                ]
            ]
        ])
        guard let msg = parseMessageInfo(result) else {
            throw TDError.unexpectedResponse
        }
        return msg
    }

    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "forwardMessages",
            "chat_id": toChatId,
            "from_chat_id": fromChatId,
            "message_ids": [messageId],
            "send_copy": false,
            "remove_caption": false
        ])
    }

    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo] {
        let result: [String: Any]
        if let chatId {
            result = try await throttledSend([
                "@type": "searchChatMessages",
                "chat_id": chatId,
                "query": query,
                "limit": AppConstants.Message.searchLimit
            ])
        } else {
            result = try await throttledSend([
                "@type": "searchMessages",
                "chat_list": ["@type": "chatListMain"],
                "query": query,
                "limit": AppConstants.Message.searchLimit
            ])
        }

        guard let messages = result["messages"] as? [[String: Any]] else {
            return []
        }
        var parsed = messages.compactMap { parseMessageInfo($0) }
        if let chatId {
            parsed.removeAll { $0.chatId != chatId }
        }
        await resolveMessageNames(&parsed)
        return parsed
    }
}
