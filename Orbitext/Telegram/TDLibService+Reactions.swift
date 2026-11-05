import Foundation
import os

// MARK: - Reactions and typing

extension TDLibService {
    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String] {
        let result = try await throttledSend([
            "@type": "getMessageAvailableReactions",
            "chat_id": chatId,
            "message_id": messageId,
            "row_size": 8
        ])
        return collectAvailableReactionEmojis(from: result)
    }

    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        let normalizedEmoji = emoji.normalizedReactionEmoji
        _ = try await throttledSend([
            "@type": "addMessageReaction",
            "chat_id": chatId,
            "message_id": messageId,
            "reaction_type": [
                "@type": "reactionTypeEmoji",
                "emoji": normalizedEmoji
            ],
            "is_big": false,
            "update_recent_reactions": true
        ])
    }

    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        let normalizedEmoji = emoji.normalizedReactionEmoji
        _ = try await throttledSend([
            "@type": "removeMessageReaction",
            "chat_id": chatId,
            "message_id": messageId,
            "reaction_type": [
                "@type": "reactionTypeEmoji",
                "emoji": normalizedEmoji
            ]
        ])
    }

    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        let result = try await throttledSend([
            "@type": "getMessageProperties",
            "chat_id": chatId,
            "message_id": messageId
        ])
        return parseMessageProperties(from: result)
    }

    func parseMessageProperties(from value: Any?) -> MessageProperties {
        guard let dict = normalizeDictionary(value) else { return .default }
        var props = MessageProperties()
        props.canBeEdited = dict["can_be_edited"] as? Bool ?? false
        props.canBeDeletedOnlyForSelf = dict["can_be_deleted_only_for_self"] as? Bool ?? false
        props.canBeDeletedForAllUsers = dict["can_be_deleted_for_all_users"] as? Bool ?? false
        props.canBeForwarded = dict["can_be_forwarded"] as? Bool ?? false
        props.canBeReplied = dict["can_be_replied"] as? Bool ?? false
        props.canBeSaved = dict["can_be_saved"] as? Bool ?? false
        props.canBePinned = dict["can_be_pinned"] as? Bool ?? false
        props.isResolved = true
        return props
    }

    func sendTyping(chatId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "sendChatAction",
            "chat_id": chatId,
            "action": ["@type": "chatActionTyping"]
        ])
    }

    private func collectAvailableReactionEmojis(from value: Any?) -> [String] {
        var result: [String] = []
        collectAvailableReactionEmojis(into: &result, from: value)
        return Array(NSOrderedSet(array: result)) as? [String] ?? result
    }

    private func collectAvailableReactionEmojis(into result: inout [String], from value: Any?) {
        if let dict = normalizeDictionary(value) {
            let type = dict["@type"] as? String
            if type == "reactionTypeEmoji", let emoji = dict["emoji"] as? String {
                result.append(emoji.normalizedReactionEmoji)
            }
            for child in dict.values {
                collectAvailableReactionEmojis(into: &result, from: child)
            }
            return
        }

        if let array = normalizeArray(value) {
            for item in array {
                collectAvailableReactionEmojis(into: &result, from: item)
            }
        }
    }
}
