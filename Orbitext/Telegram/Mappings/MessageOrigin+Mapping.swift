import Foundation

// MARK: - MessageOrigin from typed TDApi

//
// The closures that name users and chats are injected so the mapping is
// usable from unit tests without a live TDLibService.

extension MessageOrigin {
    /// Build an origin from the generated TDApi.MessageOrigin. Returns nil for
    /// an origin kind newer than the schema so callers can show the message
    /// as not forwarded. An empty `author_signature` becomes nil (per UI
    /// display rules); a user or chat the closures cannot name keeps the
    /// `#user:ID` marker or a "?" title for the name resolver.
    init?(
        tdApi origin: TDApi.MessageOrigin,
        resolveUserName: (Int64) -> String?,
        resolveChatTitle: (Int64) -> String?
    ) {
        switch origin {
        case .messageOriginUser(let user):
            let name = resolveUserName(user.senderUserId).flatMap { $0.isEmpty ? nil : $0 }
            self = .user(userId: user.senderUserId, name: name ?? "#user:\(user.senderUserId)")
        case .messageOriginHiddenUser(let hidden):
            self = .hiddenUser(name: hidden.senderName)
        case .messageOriginChat(let chat):
            self = .chat(
                chatId: chat.senderChatId,
                title: resolveChatTitle(chat.senderChatId) ?? "?",
                authorSignature: chat.authorSignature.isEmpty ? nil : chat.authorSignature
            )
        case .messageOriginChannel(let channel):
            self = .channel(
                chatId: channel.chatId,
                title: resolveChatTitle(channel.chatId) ?? "?",
                authorSignature: channel.authorSignature.isEmpty ? nil : channel.authorSignature
            )
        case .unknown:
            return nil
        }
    }

    /// TDLib serialises Int64 as either a JSON number or a string
    /// (precision-preserving). Mirror TDLibService.toInt64 for the raw-dict
    /// bot mappings, which run without a TDLibService instance.
    static func toInt64(_ value: Any?) -> Int64 {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let n = Int64(s) { return n }
        return 0
    }
}
