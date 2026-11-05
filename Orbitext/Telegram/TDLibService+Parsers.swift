import Foundation
import os

// MARK: - Chat and contact parsers and helpers

extension TDLibService {
    /// Route every chat dict through the typed `TDApi.Chat` pipeline.
    /// `parseChatInfoTyped` only returns nil for a fully empty dict
    /// (no `id` and no `@type`); for that degenerate case we return a
    /// zero-id ChatInfo so callers do not have to handle Optional.
    func parseChatInfo(_ dict: [String: Any]) -> ChatInfo {
        return parseChatInfoTyped(dict) ?? ChatInfo(
            id: 0,
            title: "",
            lastMessage: nil,
            unreadCount: 0,
            photoFileId: nil,
            isGroup: false,
            isChannel: false,
            isMuted: false,
            order: 0,
            isPinned: false,
            draftMessage: nil,
            isOnline: false,
            lastReadOutboxMessageId: 0,
            mentionCount: 0,
            reactionCount: 0
        )
    }

    /// A user as TDLib sends it (getMe and tests); remembers it like getUser does.
    func parseContactInfo(_ user: [String: Any]) -> ContactInfo {
        let info = UserInfo(tdApi: TDApi.decodeUser(user))
        userCache.set(info.id, info)
        return ContactInfo(user: info)
    }

    func normalizeDictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let nsDict = value as? NSDictionary {
            // Force-bridge each key to String to handle __NSCFString keys
            var result = [String: Any](minimumCapacity: nsDict.count)
            for (k, v) in nsDict {
                if let key = k as? String { result[key] = v }
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }

    func normalizeArray(_ value: Any?) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        if let nsArray = value as? NSArray {
            return nsArray.map(\.self)
        }
        return nil
    }

    /// Normalize a `[String: Any]` dictionary by re-bridging NSDictionary keys.
    /// Avoids expensive JSON roundtrip.
    func normalizeContent(_ content: [String: Any]) -> [String: Any] {
        // Already a Swift dict - just recurse one level for nested NSDictionaries
        var result = [String: Any](minimumCapacity: content.count)
        for (key, value) in content {
            if let nested = value as? NSDictionary {
                result[key] = normalizeDictionary(nested) ?? value
            } else if let nested = value as? NSArray {
                result[key] = normalizeArray(nested) ?? value
            } else {
                result[key] = value
            }
        }
        return result
    }

    func extractDraftText(from dict: [String: Any]) -> String? {
        guard let draftMessage = dict["draft_message"] as? [String: Any],
              let inputMsg = draftMessage["input_message_text"] as? [String: Any],
              let text = inputMsg["text"] as? [String: Any],
              let textStr = text["text"] as? String,
              !textStr.isEmpty else {
            return nil
        }
        return textStr
    }

    // MARK: - Helpers

    // MARK: - Typed Chat pipeline

    /// New path: decode the chat dict into a typed `TDApi.Chat` and run it
    /// through `ChatInfo.init(tdApi:...)`. Returns nil only if the input
    /// fails the minimum sanity check (no id and no @type field), which
    /// lets the legacy walker handle unexpected shapes during the
    /// transition to typed parsing.
    func parseChatInfoTyped(_ dict: [String: Any]) -> ChatInfo? {
        guard dict["id"] != nil || dict["@type"] != nil else { return nil }
        let typed = TDApi.decodeChat(dict)

        let lastMessage = typed.lastMessage.flatMap { MessageInfo(tdApi: $0, service: self) }

        // Service-scoped overrides: Saved Messages title + online status.
        var savedTitle: String? = nil
        var isOnline = false
        if case .chatTypePrivate(let priv) = typed.type {
            let userId = priv.userId
            if userId != 0 && userId == myUserId {
                savedTitle = L10n.string("Saved Messages")
            }
            isOnline = userCache.get(userId)?.status.isOnline ?? false
        }

        return ChatInfo(
            tdApi: typed,
            lastMessage: lastMessage,
            reactionCount: Int(typed.unreadReactionCount),
            savedMessagesTitle: savedTitle,
            isOnline: isOnline
        )
    }

    func toInt64(_ value: Any?) -> Int64 {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let s = value as? String, let i = Int64(s) { return i }
        if let d = value as? Double { return Int64(d) }
        return 0
    }
}
