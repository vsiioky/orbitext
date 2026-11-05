import Foundation
@testable import OrbitextWatch

/// Forwards every transport requirement to a MockTelegramService. A double
/// that gates one call subclasses this and overrides only that call, so a new
/// requirement on the protocol needs one forwarding line here instead of one
/// in every double. A requirement that has a default (in the protocol
/// extensions) still needs its line here: the compiler accepts the default,
/// and ForwardingTelegramServiceTests must push it through the base.
///
/// Main-actor isolated like the mock it wraps; the synchronous requirements
/// are `nonisolated` and go through the mock, which asserts the main actor.
@MainActor
class ForwardingTelegramService: @preconcurrency TelegramServiceProtocol {
    nonisolated let mock = MockTelegramService()
    nonisolated var events: AsyncStream<TDLibEvent> { mock.events }
    nonisolated var currentUserID: Int64? { mock.currentUserID }
    nonisolated var cacheDirectories: [URL] { mock.cacheDirectories }
    nonisolated func currentFloodWaitRemaining() -> Int? { mock.currentFloodWaitRemaining() }
    nonisolated var telemetry: TDRequestTelemetry? { mock.telemetry }
    nonisolated var clientGeneration: TDClientGeneration { mock.clientGeneration }

    // MARK: - Session lifecycle

    func start() async { await mock.start() }
    func logout() async throws { try await mock.logout() }
    func retryStartupIfNeeded() async throws -> Bool { try await mock.retryStartupIfNeeded() }
    func resetLocalSession() async throws { try await mock.resetLocalSession() }
    nonisolated func suspendForBackground() { mock.suspendForBackground() }
    nonisolated func resumeFromBackground() { mock.resumeFromBackground() }

    // MARK: - Auth

    func setPhoneNumber(_ phone: String) async throws { try await mock.setPhoneNumber(phone) }
    func setAuthCode(_ code: String) async throws { try await mock.setAuthCode(code) }
    func setPassword(_ password: String) async throws { try await mock.setPassword(password) }
    func requestQRCodeAuthentication() async throws { try await mock.requestQRCodeAuthentication() }

    // MARK: - Chats

    func getChats(limit: Int, folderId: Int64?) async throws -> [ChatInfo] {
        try await mock.getChats(limit: limit, folderId: folderId)
    }
    func getChatPage(limit: Int, folderId: Int64?) async throws -> ChatPage {
        try await mock.getChatPage(limit: limit, folderId: folderId)
    }
    func getChat(chatId: Int64) async throws -> ChatInfo { try await mock.getChat(chatId: chatId) }
    func getChat(username: String) async throws -> ChatInfo { try await mock.getChat(username: username) }
    func notificationState(chatId: Int64) async throws -> ChatNotificationState {
        try await mock.notificationState(chatId: chatId)
    }
    func createPrivateChat(userId: Int64) async throws { try await mock.createPrivateChat(userId: userId) }
    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] {
        try await mock.getMessages(chatId: chatId, fromMessageId: fromMessageId, limit: limit)
    }
    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        try await mock.sendMessage(chatId: chatId, text: text, replyToMessageId: replyToMessageId)
    }
    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo {
        try await mock.sendVoice(chatId: chatId, data: data, duration: duration)
    }
    func getRecentStickers() async throws -> [StickerOption] { try await mock.getRecentStickers() }
    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo {
        try await mock.sendSticker(chatId: chatId, sticker: sticker)
    }
    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo {
        try await mock.sendLocation(chatId: chatId, location: location)
    }
    func deleteMessage(chatId: Int64, messageId: Int64) async throws {
        try await mock.deleteMessage(chatId: chatId, messageId: messageId)
    }
    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo {
        try await mock.editMessage(chatId: chatId, messageId: messageId, newText: newText)
    }
    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws {
        try await mock.forwardMessage(fromChatId: fromChatId, messageId: messageId, toChatId: toChatId)
    }
    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        try await mock.getMessageProperties(chatId: chatId, messageId: messageId)
    }
    func markAsRead(chatId: Int64, messageId: Int64) async throws {
        try await mock.markAsRead(chatId: chatId, messageId: messageId)
    }
    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws {
        try await mock.markAsRead(chatId: chatId, messageIds: messageIds)
    }
    func pinChat(chatId: Int64, isPinned: Bool) async throws { try await mock.pinChat(chatId: chatId, isPinned: isPinned) }
    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws {
        try await mock.pinChat(chatId: chatId, in: list, isPinned: isPinned)
    }
    func muteChat(chatId: Int64, isMuted: Bool) async throws { try await mock.muteChat(chatId: chatId, isMuted: isMuted) }

    // MARK: - Chat lifecycle

    func openChat(_ chatId: Int64) async { await mock.openChat(chatId) }
    func closeChat(_ chatId: Int64) async { await mock.closeChat(chatId) }
    func openMessageContent(chatId: Int64, messageId: Int64) async {
        await mock.openMessageContent(chatId: chatId, messageId: messageId)
    }

    // MARK: - Reactions

    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        try await mock.setReaction(chatId: chatId, messageId: messageId, emoji: emoji)
    }
    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        try await mock.removeReaction(chatId: chatId, messageId: messageId, emoji: emoji)
    }
    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String] {
        try await mock.getAvailableMessageReactions(chatId: chatId, messageId: messageId)
    }

    // MARK: - Sponsored messages

    func getChatSponsoredMessages(chatId: Int64) async throws -> SponsoredMessageBatch {
        try await mock.getChatSponsoredMessages(chatId: chatId)
    }

    func viewSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        try await mock.viewSponsoredMessage(chatId: chatId, messageId: messageId)
    }

    func clickSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        try await mock.clickSponsoredMessage(chatId: chatId, messageId: messageId)
    }

    func reportSponsoredMessage(chatId: Int64, messageId: Int64, optionId: Data) async throws -> SponsoredReportResult {
        try await mock.reportSponsoredMessage(chatId: chatId, messageId: messageId, optionId: optionId)
    }

    // MARK: - Bots

    func getCallbackQueryAnswer(chatId: Int64, messageId: Int64, data: String) async throws -> BotCallbackAnswer {
        try await mock.getCallbackQueryAnswer(chatId: chatId, messageId: messageId, data: data)
    }
    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        try await mock.getReplyMarkupMessage(chatId: chatId)
    }
    func deleteChatReplyMarkup(chatId: Int64, messageId: Int64) async throws {
        try await mock.deleteChatReplyMarkup(chatId: chatId, messageId: messageId)
    }
    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo] { try await mock.getBotCommands(chatId: chatId) }
    func sharePhoneNumber(chatId: Int64) async throws -> MessageInfo { try await mock.sharePhoneNumber(chatId: chatId) }

    // MARK: - Typing, search, folders, drafts

    func sendTyping(chatId: Int64) async throws { try await mock.sendTyping(chatId: chatId) }
    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo] {
        try await mock.searchMessages(query: query, chatId: chatId)
    }
    func getChatFolders() async throws -> [ChatFolder] { try await mock.getChatFolders() }
    func setDraft(chatId: Int64, text: String?) async throws { try await mock.setDraft(chatId: chatId, text: text) }
    func getDraft(chatId: Int64) async throws -> String? { try await mock.getDraft(chatId: chatId) }

    // MARK: - Push

    func updatePushDeviceToken(_ token: Data) async { await mock.updatePushDeviceToken(token) }
    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool {
        try await mock.handleRemotePush(payload: payload)
    }

    // MARK: - Files and contacts

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        try await mock.downloadFile(fileId: fileId, priority: priority)
    }
    func localFileURL(fileId: String, priority: DownloadPriorityHandle) async throws -> URL {
        try await mock.localFileURL(fileId: fileId, priority: priority)
    }
    func downloadedFileURL(fileId: String) async -> URL? { await mock.downloadedFileURL(fileId: fileId) }
    func getContact(userId: Int64) async throws -> ContactInfo { try await mock.getContact(userId: userId) }
    func getContacts() async throws -> [ContactInfo] { try await mock.getContacts() }
    func searchContacts(query: String) async throws -> [ContactInfo] { try await mock.searchContacts(query: query) }
    func getMe() async throws -> ContactInfo { try await mock.getMe() }
    func getGroupInfo(chatId: Int64) async throws -> GroupInfo { try await mock.getGroupInfo(chatId: chatId) }

    // MARK: - Storage

    func clearFileCache() async throws { try await mock.clearFileCache() }
}
