#if DEBUG
import Foundation
import Synchronization

/// A Telegram service that answers from `DemoContent`, with no network, no
/// TDLib and no account. It exists for screenshots and demos: the app takes it
/// in place of the TDLib transport when launched in demo mode (`DemoLaunch`).
///
/// Writes (sending, pinning, muting, reading) change an in-memory copy and
/// emit the same events the real transport would, so the screens behave as
/// they do on a signed-in watch. Nothing is stored beyond the process.
final class DemoTelegramService: TelegramServiceProtocol {
    /// Where the app finds itself on launch.
    enum Startup: Equatable, Sendable {
        case signedIn
        case signIn
        case qrLogin
    }

    /// The link the demo sign-in screen turns into a QR code. It names no account.
    static let qrLink = "tg://login?token=DEMO"

    let events: AsyncStream<TDLibEvent>
    let content: DemoContent
    let state: Mutex<State>
    private let continuation: AsyncStream<TDLibEvent>.Continuation

    struct State {
        var startup: Startup
        var chats: [Int64: ChatInfo]
        var messages: [Int64: [MessageInfo]]
        var drafts: [Int64: String]
        var generation = TDClientGeneration.initial
    }

    init(content: DemoContent = DemoContent(), startup: Startup = .signedIn) {
        let (stream, continuation) = AsyncStream<TDLibEvent>.makeStream()
        events = stream
        self.continuation = continuation
        self.content = content
        state = Mutex(State(
            startup: startup,
            chats: Dictionary(uniqueKeysWithValues: content.chats.map { ($0.id, $0) }),
            messages: content.messages,
            drafts: [:]
        ))
    }

    deinit {
        continuation.finish()
    }

    func emit(_ event: TDLibEvent) {
        continuation.yield(event)
    }

    var currentUserID: Int64? { DemoContent.meId }

    var clientGeneration: TDClientGeneration {
        state.withLock { $0.generation }
    }

    // MARK: - Session

    func start() async {
        switch state.withLock({ $0.startup }) {
        case .signedIn:
            emit(.authStateChanged(.ready))
        case .signIn:
            emit(.authStateChanged(.waitPhoneNumber))
        case .qrLogin:
            emit(.authStateChanged(.waitOtherDeviceConfirmation))
            emit(.qrCodeLink(Self.qrLink))
        }
        emit(.connectionStateChanged(.ready))
    }

    func logout() async throws {
        endSession()
    }

    func resetLocalSession() async throws {
        endSession()
    }

    func retryStartupIfNeeded() async throws -> Bool {
        false
    }

    func suspendForBackground() {}

    func resumeFromBackground() {}

    /// What the transport does when its client ends: the generation moves on
    /// and the next start finds the sign-in screen.
    private func endSession() {
        let generation = state.withLock { state -> TDClientGeneration in
            state.generation = state.generation.next()
            state.startup = .signIn
            return state.generation
        }
        emit(.clientGenerationChanged(generation))
        emit(.authStateChanged(.waitPhoneNumber))
    }

    // MARK: - Auth

    func setPhoneNumber(_ phone: String) async throws {
        emit(.authStateChanged(.waitCode))
    }

    func setAuthCode(_ code: String) async throws {
        completeSignIn()
    }

    func setPassword(_ password: String) async throws {
        completeSignIn()
    }

    func requestQRCodeAuthentication() async throws {
        emit(.authStateChanged(.waitOtherDeviceConfirmation))
        emit(.qrCodeLink(Self.qrLink))
    }

    private func completeSignIn() {
        state.withLock { $0.startup = .signedIn }
        emit(.authStateChanged(.ready))
    }

    // MARK: - Chats

    func getChats(limit: Int, folderId: Int64?) async throws -> [ChatInfo] {
        try await getChatPage(limit: limit, folderId: folderId).chats
    }

    func getChatPage(limit: Int, folderId: Int64?) async throws -> ChatPage {
        let members = folderId.map { content.folderMembers[$0] ?? [] }
        let chats = state.withLock { state in
            state.chats.values.filter { members?.contains($0.id) ?? true }
        }
        let page = chats.sorted { ($0.order, $0.id) > ($1.order, $1.id) }.prefix(limit)
        return ChatPage(chats: Array(page), isComplete: true)
    }

    func getChat(chatId: Int64) async throws -> ChatInfo {
        guard let chat = state.withLock({ $0.chats[chatId] }) else { throw TDError.chatNotFound }
        return chat
    }

    func getChat(username: String) async throws -> ChatInfo {
        throw TDError.chatNotFound
    }

    func notificationState(chatId: Int64) async throws -> ChatNotificationState {
        let chat = try await getChat(chatId: chatId)
        let folderIds = content.folderMembers.filter { $0.value.contains(chatId) }.keys
        return ChatNotificationState(
            title: chat.title, isMuted: chat.isMuted, lastReadInboxMessageId: 0, folderIds: Set(folderIds)
        )
    }

    func createPrivateChat(userId: Int64) async throws {}

    func getChatFolders() async throws -> [ChatFolder] {
        content.folders
    }

    func pinChat(chatId: Int64, isPinned: Bool) async throws {
        try await pinChat(chatId: chatId, in: .main, isPinned: isPinned)
    }

    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws {
        guard let chat = update(chatId, { $0.isPinned = isPinned }) else { return }
        let position = ChatListPosition(list: list, order: chat.order, isPinned: isPinned)
        emit(.chatPositionChanged(ChatPositionUpdate(chat: chat, positions: [position], source: .explicitPosition)))
    }

    func muteChat(chatId: Int64, isMuted: Bool) async throws {
        guard let chat = update(chatId, { $0.isMuted = isMuted }) else { return }
        emit(.chatUpdated(chat))
    }

    func openChat(_ chatId: Int64) async {}

    func closeChat(_ chatId: Int64) async {}

    func setDraft(chatId: Int64, text: String?) async throws {
        state.withLock { $0.drafts[chatId] = text }
    }

    func getDraft(chatId: Int64) async throws -> String? {
        state.withLock { $0.drafts[chatId] }
    }

    /// Changes one chat and returns it, nil for an unknown id.
    func update(_ chatId: Int64, _ change: (inout ChatInfo) -> Void) -> ChatInfo? {
        state.withLock { state in
            guard var chat = state.chats[chatId] else { return nil }
            change(&chat)
            state.chats[chatId] = chat
            return chat
        }
    }

    // MARK: - People

    func getContact(userId: Int64) async throws -> ContactInfo {
        guard let contact = ([content.me] + content.contacts).first(where: { $0.id == userId }) else {
            throw TDError.chatNotFound
        }
        return contact
    }

    func getContacts() async throws -> [ContactInfo] {
        content.contacts
    }

    func searchContacts(query: String) async throws -> [ContactInfo] {
        let needle = query.lowercased()
        return content.contacts.filter {
            $0.fullName.lowercased().contains(needle) || $0.username.lowercased().contains(needle)
        }
    }

    func getMe() async throws -> ContactInfo {
        content.me
    }

    func getGroupInfo(chatId: Int64) async throws -> GroupInfo {
        content.groupInfo[chatId] ?? GroupInfo()
    }

    // MARK: - Stickers, files, push

    func getRecentStickers() async throws -> [StickerOption] {
        content.stickers
    }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        guard let data = DemoMedia.data(forFileId: fileId) else { throw TelegramServiceError.downloadFailed }
        return data
    }

    func clearFileCache() async throws {}

    func updatePushDeviceToken(_ token: Data) async {}

    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool {
        false
    }
}
#endif
