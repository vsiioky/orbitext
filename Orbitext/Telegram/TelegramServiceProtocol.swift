import Foundation

/// What decides whether a new message notifies, read fresh from TDLib: the
/// chat list is a partial, possibly stale copy, and a reconnect replays
/// messages that were already read on another device.
struct ChatNotificationState: Equatable, Sendable {
    let title: String
    /// Effective mute, including the default for this type of chat.
    let isMuted: Bool
    let lastReadInboxMessageId: Int64
    /// Folders whose loaded part contains the chat. TDLib reports a folder
    /// position only inside the part of that folder it has loaded.
    let folderIds: Set<Int64>
}

/// One answer of `getChats`.
struct ChatPage: Sendable {
    let chats: [ChatInfo]
    /// Every chat id TDLib returned became a row. A page that lost one to a
    /// failed lookup says nothing about the chats it lacks.
    let isComplete: Bool
}

/// A remote push as the transport hands it to TDLib: the payload as JSON
/// text. The system gives the app a [AnyHashable: Any] on the main actor;
/// text is what can go from there into the transport.
struct RemotePushPayload: Sendable, Equatable {
    let json: String

    init(json: String) {
        self.json = json
    }

    /// The keys as strings, sorted.
    init(userInfo: [AnyHashable: Any]) throws {
        var normalizedPayload: [String: Any] = [:]
        normalizedPayload.reserveCapacity(userInfo.count)
        for (key, value) in userInfo {
            normalizedPayload[String(describing: key)] = value
        }

        let data = try JSONSerialization.data(withJSONObject: normalizedPayload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw TDError.serializationFailed
        }
        self.json = json
    }
}

enum ChatListActionError: Error {
    /// The service cannot act on that chat list.
    case unsupported
}

protocol TelegramServiceProtocol: TelegramSessionLifecycle, TelegramFileAccess, TelegramDiagnostics {
    var events: AsyncStream<TDLibEvent> { get }
    /// Cached authenticated identity; nil until the service knows the user.
    var currentUserID: Int64? { get }

    // MARK: - Auth

    func setPhoneNumber(_ phone: String) async throws
    func setAuthCode(_ code: String) async throws
    func setPassword(_ password: String) async throws
    func requestQRCodeAuthentication() async throws

    // MARK: - Chats

    func getChats(limit: Int, folderId: Int64?) async throws -> [ChatInfo]
    func getChatPage(limit: Int, folderId: Int64?) async throws -> ChatPage
    func getChat(chatId: Int64) async throws -> ChatInfo
    func getChat(username: String) async throws -> ChatInfo
    func notificationState(chatId: Int64) async throws -> ChatNotificationState
    /// TDLib refuses messages to a user until their private chat exists.
    func createPrivateChat(userId: Int64) async throws
    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo]
    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo
    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo
    func getRecentStickers() async throws -> [StickerOption]
    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo
    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo
    func deleteMessage(chatId: Int64, messageId: Int64) async throws
    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo
    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws
    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties
    func markAsRead(chatId: Int64, messageId: Int64) async throws
    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws
    func pinChat(chatId: Int64, isPinned: Bool) async throws
    /// Pins or unpins in one chat list: each list keeps its own pinned chats.
    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws
    func muteChat(chatId: Int64, isMuted: Bool) async throws

    // MARK: - Chat lifecycle (openChat / closeChat hints to TDLib)

    func openChat(_ chatId: Int64) async
    func closeChat(_ chatId: Int64) async

    /// Tell TDLib the user actually consumed the message content (started
    /// playing a voice note, opened a view-once photo / video). TDLib uses
    /// this to mark voice messages as listened across devices and to enforce
    /// view-once / self-destruct lifecycles.
    func openMessageContent(chatId: Int64, messageId: Int64) async

    // MARK: - Reactions

    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws
    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws
    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String]

    // MARK: - Sponsored messages (Telegram API Terms of Service 3.3)

    /// The ads of a channel; TDLib returns none for other chats.
    func getChatSponsoredMessages(chatId: Int64) async throws -> SponsoredMessageBatch
    /// The whole text of the ad was on screen.
    func viewSponsoredMessage(chatId: Int64, messageId: Int64) async throws
    /// The user followed the ad's link.
    func clickSponsoredMessage(chatId: Int64, messageId: Int64) async throws
    func reportSponsoredMessage(chatId: Int64, messageId: Int64, optionId: Data) async throws -> SponsoredReportResult

    // MARK: - Bots

    func getCallbackQueryAnswer(chatId: Int64, messageId: Int64, data: String) async throws -> BotCallbackAnswer
    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo?
    func deleteChatReplyMarkup(chatId: Int64, messageId: Int64) async throws
    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo]
    func sharePhoneNumber(chatId: Int64) async throws -> MessageInfo

    // MARK: - Typing

    func sendTyping(chatId: Int64) async throws

    // MARK: - Search

    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo]

    // MARK: - Folders

    func getChatFolders() async throws -> [ChatFolder]

    // MARK: - Drafts

    func setDraft(chatId: Int64, text: String?) async throws
    func getDraft(chatId: Int64) async throws -> String?

    // MARK: - Lifecycle

    func updatePushDeviceToken(_ token: Data) async
    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool

    // MARK: - Files & Contacts

    func getContact(userId: Int64) async throws -> ContactInfo
    func getContacts() async throws -> [ContactInfo]
    func searchContacts(query: String) async throws -> [ContactInfo]
    func getMe() async throws -> ContactInfo
    func getGroupInfo(chatId: Int64) async throws -> GroupInfo

    // MARK: - Storage

    /// Clear cache: deletes the media the transport downloaded, of every
    /// type, and the copies of sent voice notes it is done with. A file shown
    /// again downloads again. Returns once the files are gone, so a size read
    /// afterwards is the new one.
    func clearFileCache() async throws
}

/// Defaults let a narrow service skip a requirement, and let a forwarding test
/// double forget one without a compile error. Prefer a requirement without a
/// default; when one needs a default, add its forwarder to
/// ForwardingTelegramService and a line to ForwardingTelegramServiceTests.
extension TelegramServiceProtocol {
    var currentUserID: Int64? { nil }

    /// Saved Messages is the current user's private chat, independent of title.
    func isSelfChat(chatId: Int64) -> Bool {
        guard let currentUserID, currentUserID != 0 else { return false }
        return chatId == currentUserID
    }

    /// Services that cannot tell whether a page is complete never claim it.
    func getChatPage(limit: Int, folderId: Int64?) async throws -> ChatPage {
        let chats = try await getChats(limit: limit, folderId: folderId)
        return ChatPage(chats: chats, isComplete: false)
    }

    /// Services that only know the Main list can keep that narrow
    /// implementation; pinning in another list is never reported as success.
    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws {
        guard list == .main else { throw ChatListActionError.unsupported }
        try await pinChat(chatId: chatId, isPinned: isPinned)
    }

    /// Older test-only services can keep their narrow implementation. Real and
    /// preview services implement these methods; unsupported is never success.
    func getRecentStickers() async throws -> [StickerOption] {
        throw ChatAttachmentError.unsupported
    }

    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo {
        throw ChatAttachmentError.unsupported
    }

    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo {
        throw ChatAttachmentError.unsupported
    }

    func getCallbackQueryAnswer(chatId: Int64, messageId: Int64, data: String) async throws -> BotCallbackAnswer {
        throw BotInteractionError.unsupported
    }

    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        throw BotInteractionError.unsupported
    }

    func deleteChatReplyMarkup(chatId: Int64, messageId: Int64) async throws {
        throw BotInteractionError.unsupported
    }

    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo] {
        throw BotInteractionError.unsupported
    }

    func sharePhoneNumber(chatId: Int64) async throws -> MessageInfo {
        throw BotInteractionError.unsupported
    }
}
