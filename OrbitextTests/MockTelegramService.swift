import Foundation
@testable import OrbitextWatch

/// Holds a mock request in flight until the test opens it, so that a test can
/// look at the state while the request is pending without racing a timer.
@MainActor
final class MockRequestGate {
    /// Requests that reached the gate, whether or not they passed it yet.
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

/// Main-actor isolated: tests configure and inspect this state on the main
/// actor while the code under test calls in from other executors, so every
/// async call hops to the main actor instead of racing with the test.
///
/// The synchronous requirements cannot hop. In Swift 5 mode a
/// `@preconcurrency` conformance does not check isolation at run time, so
/// they are `nonisolated` and assert the main actor themselves: a call from
/// another thread traps instead of racing silently.
///
/// Trade-off: calls from the main-actor app code no longer suspend, and
/// events the mock emits are always handled after the caller resumes. The
/// real service allows either order, so tests that need the other order or
/// an in-flight window use the explicit delays and gates.
@MainActor
final class MockTelegramService: @preconcurrency TelegramServiceProtocol {
    nonisolated let events: AsyncStream<TDLibEvent>
    private nonisolated let continuation: AsyncStream<TDLibEvent>.Continuation

    var authState: AuthState = .waitPhoneNumber
    var chats: [ChatInfo] = []
    var chatsById: [Int64: ChatInfo] = [:]
    var chatFolderIdsByChatId: [Int64: Set<Int64>] = [:]
    var notificationStateByChatId: [Int64: ChatNotificationState] = [:]
    var notificationStateDelay: Duration?
    var createdPrivateChatUserIds: [Int64] = []
    var createPrivateChatError: Error?
    private var storedCurrentUserID: Int64?
    nonisolated var currentUserID: Int64? {
        get { MainActor.assumeIsolated { storedCurrentUserID } }
        set { MainActor.assumeIsolated { storedCurrentUserID = newValue } }
    }
    private var storedCacheDirectories: [URL] = []
    /// What Clear cache deletes of the transport's files, for the cache size.
    nonisolated var cacheDirectories: [URL] {
        get { MainActor.assumeIsolated { storedCacheDirectories } }
        set { MainActor.assumeIsolated { storedCacheDirectories = newValue } }
    }

    private var storedFloodWaitRemaining: Int?
    nonisolated var floodWaitRemainingSeconds: Int? {
        get { MainActor.assumeIsolated { storedFloodWaitRemaining } }
        set { MainActor.assumeIsolated { storedFloodWaitRemaining = newValue } }
    }

    nonisolated func currentFloodWaitRemaining() -> Int? { floodWaitRemainingSeconds }

    private var storedClientGeneration = TDClientGeneration.initial
    /// The mock keeps one client for life unless a test moves the generation.
    nonisolated var clientGeneration: TDClientGeneration {
        get { MainActor.assumeIsolated { storedClientGeneration } }
        set { MainActor.assumeIsolated { storedClientGeneration = newValue } }
    }

    private var storedTelemetry: TDRequestTelemetry?
    /// Request telemetry; nil unless a test sets one, as in a build without it.
    nonisolated var telemetry: TDRequestTelemetry? {
        get { MainActor.assumeIsolated { storedTelemetry } }
        set { MainActor.assumeIsolated { storedTelemetry = newValue } }
    }
    var messagesByChatId: [Int64: [MessageInfo]] = [:]
    var folders: [ChatFolder] = []
    var searchResults: [MessageInfo] = []
    var getMessagesScriptedResponses: [[MessageInfo]] = []
    var contacts: [ContactInfo] = []
    var me: ContactInfo?
    var groupInfo = GroupInfo()
    var drafts: [Int64: String] = [:]
    var setDraftCalls: [(chatId: Int64, text: String?)] = []
    /// How long a setDraft takes, by the text it carries; none by default.
    var setDraftDelay: ((String?) -> Duration)?
    /// Whether a delayed setDraft keeps running when its task is cancelled,
    /// as a request already handed to TDLib does.
    var setDraftIgnoresCancellation = false
    /// The drafts in the order their writes finished.
    var setDraftCompletions: [String?] = []
    var publicChatsByUsername: [String: ChatInfo] = [:]
    var availableReactions: [String] = ["👍", "❤", "🔥"]
    var sponsoredBatches: [Int64: SponsoredMessageBatch] = [:]
    var sponsoredError: Error?
    var sponsoredRequests: [Int64] = []
    var viewedSponsored: [(chatId: Int64, messageId: Int64)] = []
    var clickedSponsored: [(chatId: Int64, messageId: Int64)] = []
    var reportedSponsored: [(chatId: Int64, messageId: Int64, optionId: Data)] = []
    var sponsoredReportResult: SponsoredReportResult = .reported
    var messagePropertiesByMessage: [Int64: MessageProperties] = [:]
    var defaultMessageProperties: MessageProperties = .default
    var getMessagePropertiesError: Error?
    var getMessagePropertiesCalls: [(chatId: Int64, messageId: Int64)] = []
    var downloadedFiles: [String: Data] = [:]
    /// Files the transport holds on disk, by file id.
    var localFileURLs: [String: URL] = [:]
    var localFileURLError: Error?
    var requestedLocalFileURLs: [String] = []
    /// The priority handle of the latest download or local file request, by file id.
    var downloadPriorities: [String: DownloadPriorityHandle] = [:]
    var recentStickers: [StickerOption] = []
    var getRecentStickersCallCount = 0
    var sentStickers: [(chatId: Int64, sticker: StickerOption)] = []
    var sentLocations: [(chatId: Int64, location: SharedLocation)] = []
    var getRecentStickersError: Error?
    var sendStickerError: Error?
    var sendLocationError: Error?
    var callbackAnswer = BotCallbackAnswer()
    var callbackQueryError: Error?
    var callbackQueries: [(chatId: Int64, messageId: Int64, data: String)] = []
    var replyMarkupMessagesByChatId: [Int64: MessageInfo] = [:]
    var replyMarkupMessageError: Error?
    var deletedReplyMarkups: [(chatId: Int64, messageId: Int64)] = []
    var botCommandsByChatId: [Int64: [BotCommandInfo]] = [:]
    var botCommandsError: Error?
    var sharedPhoneNumberChats: [Int64] = []
    var sharePhoneNumberError: Error?

    var startCallCount = 0
    var resumeCallCount = 0
    var suspendCallCount = 0
    var logoutCallCount = 0
    var handledRemotePushPayloads: [[String: Any]] = []
    var registeredPushDeviceTokens: [Data] = []
    var remotePushResult = true
    var emitReadyConnectionOnStart = true
    var emitReadyConnectionOnResume = true

    /// Whether the last `start()` failed: the only startup a retry restarts,
    /// as in `TDLibService`.
    private(set) var hasStartupFailure = false
    var retryStartupCallCount = 0
    var retryStartupError: Error?
    var resetLocalSessionCallCount = 0
    var resetLocalSessionError: Error?

    var sentPhoneNumbers: [String] = []
    var sentCodes: [String] = []
    var sentPasswords: [String] = []
    var qrRequestCount = 0
    var authActionDelay: Duration?
    var sentMessages: [(chatId: Int64, text: String, replyToMessageId: Int64?)] = []
    var sentVoices: [(chatId: Int64, duration: Int)] = []
    var deletedMessages: [(chatId: Int64, messageId: Int64)] = []
    var editedMessages: [(chatId: Int64, messageId: Int64, text: String)] = []
    var forwardedMessages: [(fromChatId: Int64, messageId: Int64, toChatId: Int64)] = []
    var readReceipts: [(chatId: Int64, messageId: Int64)] = []
    var pinnedChats: [(chatId: Int64, list: ChatListID, isPinned: Bool)] = []
    var mutedChats: [(chatId: Int64, isMuted: Bool)] = []
    var openedChats: [Int64] = []
    var closedChats: [Int64] = []
    var openedMessageContents: [(chatId: Int64, messageId: Int64)] = []
    var typingChats: [Int64] = []
    var readReceiptBatches: [(chatId: Int64, messageIds: [Int64])] = []
    var requestedDownloads: [String] = []
    var getChatsRequests: [(limit: Int, folderId: Int64?)] = []
    var getChatRequests: [Int64] = []
    var getMessagesRequests: [(chatId: Int64, fromMessageId: Int64, limit: Int)] = []
    var searchQueries: [(query: String, chatId: Int64?)] = []

    var startError: Error?
    var sendMessageError: Error?
    var sendVoiceError: Error?
    var deleteMessageError: Error?
    var editMessageError: Error?
    var forwardMessageError: Error?
    var markAsReadError: Error?
    var pinChatError: Error?
    var muteChatError: Error?
    var searchError: Error?
    var contactsError: Error?
    var meError: Error?
    var groupInfoError: Error?
    var clearFileCacheCallCount = 0
    /// Stands in for the transport deleting its files on Clear cache.
    var clearsFileCache: (() -> Void)?
    var clearFileCacheError: Error?
    /// How long the transport takes to delete its files.
    var clearFileCacheDelay: Duration?
    var downloadError: Error?
    var publicChatError: Error?
    var getChatsDelay: Duration?
    /// Whether the pages `getChatPage` returns count as complete.
    var getChatsPageIsComplete = true
    var getChatDelay: Duration?
    var getChatError: Error?
    var getChatFoldersDelay: Duration?
    /// While set, the request stays in flight until the gate opens.
    var pinChatGate: MockRequestGate?
    var muteChatGate: MockRequestGate?
    /// A logout or a local reset stays in flight until the gate opens.
    var logoutGate: MockRequestGate?
    var resetLocalSessionGate: MockRequestGate?
    var phoneError: Error?
    var codeError: Error?
    var passwordError: Error?
    var qrError: Error?
    var reactionError: Error?
    var logoutError: Error?

    nonisolated init() {
        let (stream, continuation) = AsyncStream<TDLibEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    nonisolated func emit(_ event: TDLibEvent) {
        continuation.yield(event)
    }

    func start() async {
        startCallCount += 1
        hasStartupFailure = startError != nil
        if let startError {
            emit(.authStateChanged(.error(startError.localizedDescription)))
            return
        }
        emit(.authStateChanged(authState))
        if authState == .ready && emitReadyConnectionOnStart {
            emit(.connectionStateChanged(.ready))
        }
    }

    func setPhoneNumber(_ phone: String) async throws {
        if let phoneError { throw phoneError }
        if let authActionDelay {
            try? await Task.sleep(for: authActionDelay)
        }
        sentPhoneNumbers.append(phone)
    }

    func setAuthCode(_ code: String) async throws {
        if let codeError { throw codeError }
        if let authActionDelay {
            try? await Task.sleep(for: authActionDelay)
        }
        sentCodes.append(code)
    }

    func setPassword(_ password: String) async throws {
        if let passwordError { throw passwordError }
        if let authActionDelay {
            try? await Task.sleep(for: authActionDelay)
        }
        sentPasswords.append(password)
    }

    func requestQRCodeAuthentication() async throws {
        if let qrError { throw qrError }
        if let authActionDelay {
            try? await Task.sleep(for: authActionDelay)
        }
        qrRequestCount += 1
    }

    func logout() async throws {
        logoutCallCount += 1
        await logoutGate?.pass()
        if let logoutError { throw logoutError }
        endSessionLocally()
    }

    func retryStartupIfNeeded() async throws -> Bool {
        retryStartupCallCount += 1
        if let retryStartupError { throw retryStartupError }
        guard hasStartupFailure else { return false }
        emit(.authStateChanged(.idle))
        await start()
        return true
    }

    func resetLocalSession() async throws {
        resetLocalSessionCallCount += 1
        await resetLocalSessionGate?.pass()
        if let resetLocalSessionError { throw resetLocalSessionError }
        endSessionLocally()
    }

    /// What TDLibService does when it retires its client: the generation
    /// advances and the stream carries the marker, so everything emitted
    /// before it belongs to the ended session.
    func retireClient() {
        clientGeneration = clientGeneration.next()
        emit(.clientGenerationChanged(clientGeneration))
    }

    /// What `TDLibService.cleanupClosedSession` leaves behind, for logout and
    /// local reset alike: no startup to retry, no known user, a fresh login.
    private func endSessionLocally() {
        retireClient()
        authState = .waitPhoneNumber
        hasStartupFailure = false
        currentUserID = nil
        emit(.authStateChanged(.waitPhoneNumber))
    }

    func getChats(limit: Int, folderId: Int64?) async throws -> [ChatInfo] {
        try await getChatPage(limit: limit, folderId: folderId).chats
    }

    func getChatPage(limit: Int, folderId: Int64?) async throws -> ChatPage {
        getChatsRequests.append((limit, folderId))
        if let getChatsDelay {
            try? await Task.sleep(for: getChatsDelay)
        }
        return ChatPage(chats: Array(chats.prefix(limit)), isComplete: getChatsPageIsComplete)
    }

    func getChat(chatId: Int64) async throws -> ChatInfo {
        getChatRequests.append(chatId)
        if let getChatDelay {
            try? await Task.sleep(for: getChatDelay)
        }
        if let getChatError { throw getChatError }
        if let chat = chatsById[chatId] {
            return chat
        }
        return chats.first(where: { $0.id == chatId })
            ?? ChatInfo(id: chatId, title: "Chat \(chatId)", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
    }

    func createPrivateChat(userId: Int64) async throws {
        if let createPrivateChatError { throw createPrivateChatError }
        createdPrivateChatUserIds.append(userId)
    }

    func notificationState(chatId: Int64) async throws -> ChatNotificationState {
        if let notificationStateDelay { try await Task.sleep(for: notificationStateDelay) }
        if let state = notificationStateByChatId[chatId] { return state }
        let chat = chatsById[chatId] ?? chats.first(where: { $0.id == chatId })
        return ChatNotificationState(
            title: chat?.title ?? "Chat \(chatId)",
            isMuted: chat?.isMuted ?? false,
            lastReadInboxMessageId: 0,
            folderIds: chatFolderIdsByChatId[chatId] ?? []
        )
    }

    func getChat(username: String) async throws -> ChatInfo {
        if let publicChatError { throw publicChatError }
        var normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedUsername.hasPrefix("@") {
            normalizedUsername.removeFirst()
        }
        normalizedUsername = normalizedUsername.lowercased()
        if let chat = publicChatsByUsername[normalizedUsername] {
            return chat
        }
        throw TDError.chatNotFound
    }

    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] {
        getMessagesRequests.append((chatId, fromMessageId, limit))
        if !getMessagesScriptedResponses.isEmpty {
            return getMessagesScriptedResponses.removeFirst()
        }

        let allMessages = messagesByChatId[chatId] ?? []
        if fromMessageId == 0 {
            return Array(allMessages.suffix(limit).reversed())
        }

        guard let anchorIndex = allMessages.firstIndex(where: { $0.id == fromMessageId }) else {
            return []
        }

        let startIndex = max(0, anchorIndex - limit)
        return Array(allMessages[startIndex..<anchorIndex].reversed())
    }

    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        if let sendMessageError { throw sendMessageError }

        sentMessages.append((chatId, text, replyToMessageId))
        let nextId = (messagesByChatId[chatId]?.map(\.id).max() ?? 0) + 1
        let message = MessageInfo(
            id: nextId,
            chatId: chatId,
            senderName: "You",
            senderId: 1,
            content: .text(FormattedString(text: text)),
            date: Date(),
            isOutgoing: true,
            isRead: true,
            replyToMessageId: replyToMessageId
        )
        messagesByChatId[chatId, default: []].append(message)
        return message
    }

    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo {
        if let sendVoiceError { throw sendVoiceError }

        sentVoices.append((chatId, duration))
        let nextId = (messagesByChatId[chatId]?.map(\.id).max() ?? 0) + 1
        let message = MessageInfo(
            id: nextId,
            chatId: chatId,
            senderName: "You",
            senderId: 1,
            content: .voice(duration: duration, fileId: "voice-\(nextId)", waveform: nil),
            date: Date(),
            isOutgoing: true,
            isRead: true
        )
        messagesByChatId[chatId, default: []].append(message)
        return message
    }

    func getRecentStickers() async throws -> [StickerOption] {
        try Task.checkCancellation()
        getRecentStickersCallCount += 1
        if let getRecentStickersError { throw getRecentStickersError }
        return recentStickers
    }

    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo {
        try Task.checkCancellation()
        guard sticker.isValid else { throw ChatAttachmentError.invalidSticker }
        if let sendStickerError { throw sendStickerError }
        sentStickers.append((chatId, sticker))
        return appendAttachment(
            chatId: chatId,
            content: .sticker(emoji: sticker.emoji, fileId: sticker.fileId, thumbnailFileId: sticker.thumbnailFileId)
        )
    }

    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo {
        try Task.checkCancellation()
        guard location.isValid else { throw ChatAttachmentError.invalidLocation }
        if let sendLocationError { throw sendLocationError }
        sentLocations.append((chatId, location))
        return appendAttachment(
            chatId: chatId,
            content: .location(latitude: location.latitude, longitude: location.longitude, livePeriod: nil)
        )
    }

    private func appendAttachment(chatId: Int64, content: MessageContent) -> MessageInfo {
        let nextId = (messagesByChatId[chatId]?.map(\.id).max() ?? 0) + 1
        let message = MessageInfo(
            id: nextId, chatId: chatId, senderName: "You", senderId: 1,
            content: content, date: Date(), isOutgoing: true, isRead: true
        )
        messagesByChatId[chatId, default: []].append(message)
        emit(.newMessage(message))
        return message
    }

    func deleteMessage(chatId: Int64, messageId: Int64) async throws {
        if let deleteMessageError { throw deleteMessageError }
        deletedMessages.append((chatId, messageId))
        messagesByChatId[chatId]?.removeAll { $0.id == messageId }
    }

    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo {
        if let editMessageError { throw editMessageError }
        editedMessages.append((chatId, messageId, newText))

        guard let index = messagesByChatId[chatId]?.firstIndex(where: { $0.id == messageId }) else {
            throw TDError.unexpectedResponse
        }

        messagesByChatId[chatId]?[index].content = .text(FormattedString(text: newText))
        guard let updated = messagesByChatId[chatId]?[index] else {
            throw TDError.unexpectedResponse
        }
        return updated
    }

    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws {
        if let forwardMessageError { throw forwardMessageError }
        forwardedMessages.append((fromChatId, messageId, toChatId))
    }

    func markAsRead(chatId: Int64, messageId: Int64) async throws {
        try await markAsRead(chatId: chatId, messageIds: [messageId])
    }

    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws {
        if let markAsReadError { throw markAsReadError }
        guard !messageIds.isEmpty else { return }
        readReceiptBatches.append((chatId, messageIds))
        readReceipts.append(contentsOf: messageIds.map { (chatId, $0) })
    }

    func pinChat(chatId: Int64, isPinned: Bool) async throws {
        try await pinChat(chatId: chatId, in: .main, isPinned: isPinned)
    }

    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws {
        await pinChatGate?.pass()
        if let pinChatError { throw pinChatError }
        pinnedChats.append((chatId, list, isPinned))
    }

    func muteChat(chatId: Int64, isMuted: Bool) async throws {
        await muteChatGate?.pass()
        if let muteChatError { throw muteChatError }
        mutedChats.append((chatId, isMuted))
    }

    func openChat(_ chatId: Int64) async {
        openedChats.append(chatId)
    }

    func closeChat(_ chatId: Int64) async {
        closedChats.append(chatId)
    }

    func openMessageContent(chatId: Int64, messageId: Int64) async {
        openedMessageContents.append((chatId, messageId))
    }

    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        if let reactionError { throw reactionError }
    }

    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {
        if let reactionError { throw reactionError }
    }

    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String] {
        availableReactions
    }

    func getChatSponsoredMessages(chatId: Int64) async throws -> SponsoredMessageBatch {
        sponsoredRequests.append(chatId)
        if let sponsoredError { throw sponsoredError }
        return sponsoredBatches[chatId] ?? SponsoredMessageBatch(messages: [], messagesBetween: 0)
    }

    func viewSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        viewedSponsored.append((chatId, messageId))
    }

    func clickSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        clickedSponsored.append((chatId, messageId))
    }

    func reportSponsoredMessage(chatId: Int64, messageId: Int64, optionId: Data) async throws -> SponsoredReportResult {
        reportedSponsored.append((chatId, messageId, optionId))
        return sponsoredReportResult
    }

    func sendTyping(chatId: Int64) async throws {
        typingChats.append(chatId)
    }

    func getCallbackQueryAnswer(chatId: Int64, messageId: Int64, data: String) async throws -> BotCallbackAnswer {
        callbackQueries.append((chatId, messageId, data))
        if let callbackQueryError { throw callbackQueryError }
        return callbackAnswer
    }

    func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        if let replyMarkupMessageError { throw replyMarkupMessageError }
        return replyMarkupMessagesByChatId[chatId]
    }

    func deleteChatReplyMarkup(chatId: Int64, messageId: Int64) async throws {
        deletedReplyMarkups.append((chatId, messageId))
        replyMarkupMessagesByChatId[chatId] = nil
    }

    func getBotCommands(chatId: Int64) async throws -> [BotCommandInfo] {
        if let botCommandsError { throw botCommandsError }
        return botCommandsByChatId[chatId] ?? []
    }

    func sharePhoneNumber(chatId: Int64) async throws -> MessageInfo {
        if let sharePhoneNumberError { throw sharePhoneNumberError }
        sharedPhoneNumberChats.append(chatId)
        return appendAttachment(chatId: chatId, content: .contact(name: me?.fullName ?? "You", phone: me?.phone ?? ""))
    }

    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        getMessagePropertiesCalls.append((chatId, messageId))
        if let getMessagePropertiesError { throw getMessagePropertiesError }
        return messagePropertiesByMessage[messageId] ?? defaultMessageProperties
    }

    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo] {
        if let searchError { throw searchError }
        searchQueries.append((query, chatId))
        if let chatId {
            return searchResults.filter { $0.chatId == chatId }
        }
        return searchResults
    }

    func getChatFolders() async throws -> [ChatFolder] {
        if let getChatFoldersDelay {
            try? await Task.sleep(for: getChatFoldersDelay)
        }
        return folders
    }

    func setDraft(chatId: Int64, text: String?) async throws {
        setDraftCalls.append((chatId: chatId, text: text))
        if let delay = setDraftDelay?(text) {
            if setDraftIgnoresCancellation {
                // An unstructured task does not inherit the cancellation.
                await Task { try? await Task.sleep(for: delay) }.value
            } else {
                try await Task.sleep(for: delay)
            }
        }
        drafts[chatId] = text
        setDraftCompletions.append(text)
    }

    func getDraft(chatId: Int64) async throws -> String? {
        drafts[chatId] ?? nil
    }

    nonisolated func suspendForBackground() {
        MainActor.assumeIsolated { suspendCallCount += 1 }
    }

    nonisolated func resumeFromBackground() {
        MainActor.assumeIsolated {
            resumeCallCount += 1
            if authState == .ready && emitReadyConnectionOnResume {
                emit(.connectionStateChanged(.ready))
            }
        }
    }

    func updatePushDeviceToken(_ token: Data) async {
        registeredPushDeviceTokens.append(token)
    }

    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool {
        let decoded = try JSONSerialization.jsonObject(with: Data(payload.json.utf8)) as? [String: Any]
        handledRemotePushPayloads.append(decoded ?? [:])
        return remotePushResult
    }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        if let downloadError { throw downloadError }
        requestedDownloads.append(fileId)
        downloadPriorities[fileId] = priority
        return downloadedFiles[fileId] ?? Data()
    }

    func downloadedFileURL(fileId: String) async -> URL? {
        localFileURLs[fileId]
    }

    func localFileURL(fileId: String, priority: DownloadPriorityHandle) async throws -> URL {
        requestedLocalFileURLs.append(fileId)
        downloadPriorities[fileId] = priority
        if let localFileURLError { throw localFileURLError }
        guard let url = localFileURLs[fileId] else { throw TelegramServiceError.downloadFailed }
        return url
    }

    func getContact(userId: Int64) async throws -> ContactInfo {
        if let contactsError { throw contactsError }
        return contacts.first(where: { $0.id == userId })
            ?? ContactInfo(id: userId, firstName: "User", lastName: "", phone: "", username: "", photoFileId: nil, isOnline: false, lastSeen: nil)
    }

    func getContacts() async throws -> [ContactInfo] {
        if let contactsError { throw contactsError }
        return contacts
    }

    func searchContacts(query: String) async throws -> [ContactInfo] {
        if let contactsError { throw contactsError }
        let lowered = query.lowercased()
        return contacts.filter {
            $0.fullName.lowercased().contains(lowered)
                || $0.username.lowercased().contains(lowered)
        }
    }

    func getMe() async throws -> ContactInfo {
        if let meError { throw meError }
        guard let me else { throw TDError.unexpectedResponse }
        return me
    }

    func getGroupInfo(chatId: Int64) async throws -> GroupInfo {
        if let groupInfoError { throw groupInfoError }
        return groupInfo
    }

    func clearFileCache() async throws {
        clearFileCacheCallCount += 1
        clearsFileCache?()
        if let clearFileCacheDelay { try await Task.sleep(for: clearFileCacheDelay) }
        if let clearFileCacheError { throw clearFileCacheError }
    }
}
