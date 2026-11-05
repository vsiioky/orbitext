import Foundation

// MARK: - MessageInfo from typed TDApi.Message

//
// Construction of a MessageInfo from the generated TDApi.Message: sender,
// content, reply, forward origin, reactions, delivery state and bot keyboard
// all come from the typed members; nothing reads the raw dict.

/// The reply members of a MessageInfo.
struct ReplyFields {
    var messageId: Int64?
    var senderName: String?
    var senderUserId: Int64?
    var preview: FormattedString?
    var senderResolved = true
}

extension ReplyFields {
    /// A message reply with its quote and the name of the replied message's
    /// origin, as far as the caches know it. Anything else (a reply to a
    /// story, a kind newer than the schema) is no reply.
    init(tdApi replyTo: TDApi.MessageReplyTo?, service: TDLibService) {
        guard case .messageReplyToMessage(let reply)? = replyTo else { return }
        messageId = reply.messageId
        if let quote = reply.quote?.text.map(FormattedString.init(tdApi:)), !quote.isEmpty {
            preview = quote
        }
        switch reply.origin {
        case .messageOriginUser(let user)?:
            if user.senderUserId != 0 {
                senderUserId = user.senderUserId
            }
            senderName = service.userCache.get(user.senderUserId)?.displayName
        case .messageOriginChat(let chat)?:
            senderName = service.chatCache.get(chat.senderChatId)?.title
        case .messageOriginChannel(let channel)?:
            senderName = service.chatCache.get(channel.chatId)?.title
        case .messageOriginHiddenUser(let hidden)?:
            senderName = hidden.senderName
        case .unknown?, nil:
            break
        }
        senderResolved = senderName != nil
    }
}

extension MessageInfo {
    /// - Parameters:
    ///   - tdApi: Decoded TDApi.Message (from `TDApi.decodeMessage`).
    ///   - service: Provides userCache/chatCache for sender, reply and
    ///     forward origin name resolution.
    /// - Returns: A fully populated MessageInfo, or nil when the message
    ///   lacks an id.
    init?(tdApi msg: TDApi.Message, service: TDLibService) {
        guard msg.id != 0 else { return nil }
        let content = msg.content.map(MessageContent.init(tdApi:)) ?? .unsupported("unknown")
        let reply = ReplyFields(tdApi: msg.replyTo, service: service)
        let forwardedOrigin = msg.forwardInfo?.origin.flatMap(service.messageOrigin(from:))
        let reactions = ReactionInfo.list(tdApi: msg.interactionInfo?.reactions?.reactions ?? [])

        // Sender: cache lookups + localised placeholder if unresolved.
        var senderName = ""
        var senderId: Int64 = 0
        var senderResolved = true
        switch msg.senderId {
        case .messageSenderUser(let user)?:
            senderId = user.userId
            if let name = service.userCache.get(senderId)?.displayName {
                senderName = name
            } else {
                senderName = msg.isOutgoing ? L10n.string("You") : L10n.string("User")
                senderResolved = (senderId == 0)
            }
        case .messageSenderChat(let chat)?:
            senderId = chat.chatId
            senderName = service.chatCache.get(senderId)?.title ?? L10n.string("Chat")
        case .unknown?, .none:
            break
        }

        let isSending: Bool
        var sendingFailure: MessageSendFailure?
        switch msg.sendingState {
        case .messageSendingStatePending?:
            isSending = true
        case .messageSendingStateFailed(let failed)?:
            isSending = false
            sendingFailure = MessageSendFailure(tdApi: failed.error)
        case .unknown?, nil:
            isSending = false
        }

        self.init(
            id: msg.id,
            chatId: msg.chatId,
            senderName: senderName,
            senderId: senderId,
            content: content,
            date: Date(timeIntervalSince1970: TimeInterval(msg.date)),
            isOutgoing: msg.isOutgoing,
            isRead: false,
            replyToMessageId: reply.messageId,
            replyToSenderName: reply.senderName,
            replyToSenderUserId: reply.senderUserId,
            replyToPreview: reply.preview,
            forwardedOrigin: forwardedOrigin,
            reactions: reactions,
            mediaAlbumId: msg.mediaAlbumId,
            senderResolved: senderResolved,
            replyToSenderResolved: reply.senderResolved,
            isSending: isSending,
            sendingFailure: sendingFailure,
            replyMarkup: msg.replyMarkup.flatMap(ReplyMarkup.init(tdApi:)),
            selfDestruct: SelfDestructPolicy(tdApi: msg.selfDestructType)
        )
    }
}

extension MessageSendFailure {
    /// A failure without a reason from TDLib reads "Failed".
    init(tdApi error: TDApi.Error?) {
        self.init(code: Int(error?.code ?? 0), message: error?.message ?? L10n.string("Failed"))
    }
}
