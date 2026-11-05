import Foundation

struct RemoteNotificationInfo: Sendable, Equatable {
    let chatId: Int64
    let chatTitle: String
    let senderName: String
    let preview: String
    let notificationKey: String
    let playSound: Bool
}

enum ChatActionKind: Sendable, Equatable, Codable, Hashable {
    case none
    case typing
    case recordingVoice
    case recordingVideo
    case uploadingPhoto
    case uploadingVideo
    case uploadingVoice
    case uploadingVideoNote
    case uploadingDocument
    case choosingSticker
    case choosingLocation
    case choosingContact
    case playingGame

    /// Maps a TDLib chatAction* @type string to a ChatActionKind.
    init(tdlibType: String) {
        switch tdlibType {
        case "chatActionTyping": self = .typing
        case "chatActionRecordingVoiceNote": self = .recordingVoice
        case "chatActionUploadingVoiceNote": self = .uploadingVoice
        case "chatActionRecordingVideoNote": self = .recordingVideo
        case "chatActionUploadingVideoNote": self = .uploadingVideoNote
        case "chatActionUploadingPhoto": self = .uploadingPhoto
        case "chatActionUploadingVideo": self = .uploadingVideo
        case "chatActionUploadingDocument": self = .uploadingDocument
        case "chatActionChoosingSticker": self = .choosingSticker
        case "chatActionChoosingLocation": self = .choosingLocation
        case "chatActionChoosingContact": self = .choosingContact
        case "chatActionStartPlayingGame": self = .playingGame
        default: self = .none
        }
    }
}

/// List membership is separate from ordinary chat fields: a bootstrap chat
/// can have no positions while its status/title/read updates are already arriving.
struct ChatPositionUpdate: Sendable {
    enum Source: Sendable, Equatable {
        /// updateChatPosition: `positions` holds the one list that changed.
        case explicitPosition
        /// updateChatLastMessage / updateChatDraftMessage: `positions` is the
        /// chat's whole vector after the change, so a list missing from it
        /// has lost the chat.
        case positionsReplacement
        /// updateNewChat: the vector the chat arrived with. A list missing
        /// from it means "not loaded yet", never removal.
        case newChat
    }

    /// The transport's mirror of the chat. Its `order` and `isPinned` are the
    /// Main list's, whichever list `positions` is about.
    let chat: ChatInfo
    let positions: [ChatListPosition]
    let source: Source
}

/// Which native TDLib client produced an event. It moves every time the
/// transport installs or retires its client, never backwards.
struct TDClientGeneration: Comparable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    /// What a transport that never replaces its client reports for life.
    static let initial = TDClientGeneration(rawValue: 0)

    func next() -> TDClientGeneration {
        TDClientGeneration(rawValue: rawValue &+ 1)
    }

    static func < (lhs: TDClientGeneration, rhs: TDClientGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { "gen\(rawValue)" }
}

/// Indirect, so an event is one pointer wherever it is queued. The
/// transport's event stream lives for the process, and its buffer keeps the
/// capacity of the largest burst it held (a cold-start sync queues thousands
/// of chat updates): with the payloads inline, every slot took 536 bytes.
indirect enum TDLibEvent: Sendable {
    /// Every later event comes from this client generation. Yielded under the
    /// transport's client lock, in the same step as the install or retirement
    /// that caused it, so the stream order matches the order of the clients.
    case clientGenerationChanged(TDClientGeneration)
    /// Emitted before a replacement native client's update stream starts.
    case chatListSessionStarted
    case authStateChanged(AuthState)
    case newMessage(MessageInfo)
    /// Replaces a temporary outgoing ID after success or failure; never a new send.
    case messageSendCompleted(oldMessageId: Int64, message: MessageInfo)
    case remoteNotification(RemoteNotificationInfo)
    case chatUpdated(ChatInfo)
    case chatPositionChanged(ChatPositionUpdate)
    case chatMentionCountChanged(chatId: Int64, count: Int)
    case chatReactionCountChanged(chatId: Int64, count: Int)
    case chatAction(chatId: Int64, names: [String], kind: ChatActionKind)
    case reactionsUpdated(chatId: Int64, messageId: Int64, reactions: [ReactionInfo])
    case deleteMessages(chatId: Int64, messageIds: [Int64])
    case connectionStateChanged(TDLibConnectionPhase)
    case foldersUpdated([ChatFolder])
    case qrCodeLink(String)
    case messageContentOpened(chatId: Int64, messageId: Int64)
    /// TDLib reported that a message's content or edited state changed,
    /// so any cached MessageProperties (canBeEdited / delete permissions /
    /// etc.) is stale and must be refetched the next time a menu is
    /// opened.
    case messagePropertiesInvalidated(chatId: Int64, messageId: Int64)
    /// updateMessageEdited: bots swap inline keyboards by editing the
    /// message; nil means the keyboard was removed.
    case messageReplyMarkupChanged(chatId: Int64, messageId: Int64, replyMarkup: ReplyMarkup?)
    /// updateMessageContent: new content of an existing message (edits,
    /// including bot menus that rewrite their text after a button press).
    case messageContentChanged(chatId: Int64, messageId: Int64, content: MessageContent)
    /// updateChatReplyMarkup: the message whose reply keyboard is active
    /// in the chat, or nil when the keyboard was removed.
    case chatReplyMarkupChanged(chatId: Int64, message: MessageInfo?)
}
