import XCTest
@testable import OrbitextWatch

/// The list on screen is a projection of what TDLib reported per chat list,
/// not a page that every handler patches.
@MainActor
final class ChatListProjectionTests: XCTestCase {
    private var service: MockTelegramService!
    private var widgetSync: MockWidgetSync!
    private var notificationManager: MockNotificationManager!
    private var draftStore: DraftStore!
    private var draftDirectory: URL!
    private var appDraftsBefore: [Int64: String] = [:]
    private var repo: ChatRepository!

    override func setUp() async throws {
        ListCache<ChatInfo>(filename: "cached_chats.json").clear()
        service = MockTelegramService()
        widgetSync = MockWidgetSync()
        notificationManager = MockNotificationManager()
        appDraftsBefore = DraftStore().allDrafts()
        // Drafts are written at once: the app's own file would keep this
        // test's drafts for every test that loads the same chat id later.
        draftDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatListProjectionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        draftStore = DraftStore(fileURL: draftDirectory.appendingPathComponent("drafts.json"))
        repo = ChatRepository(
            service: service,
            draftStore: draftStore,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
    }

    override func tearDown() async throws {
        XCTAssertEqual(DraftStore().allDrafts(), appDraftsBefore, "the test wrote into the app's own draft file")
        repo?.invalidateChatListPrefetch()
        repo?.missingChatFetchTask?.cancel()
        repo?.folderChatListCaches.values.forEach { $0.clear() }
        repo?.chatListCache.clear()
        repo = nil
        draftStore = nil
        try? FileManager.default.removeItem(at: draftDirectory)
        draftDirectory = nil
        notificationManager = nil
        widgetSync = nil
        service = nil
    }

    // MARK: - Folders follow their own positions

    func testFolderViewUsesFolderOrderAndFolderPin() async {
        showFolder7()
        service.chats = [chat(1, order: 10), chat(2, order: 20)]
        await repo.loadChats()
        XCTAssertEqual(repo.chats.map(\.id), [2, 1], "a page row carries the Main order")

        repo.handleChatPositionUpdate(folderPosition(chat(1, order: 10), order: 100, pinned: true))
        repo.handleChatPositionUpdate(folderPosition(chat(2, order: 20), order: 5))

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.map(\.order), [100, 5])
        XCTAssertEqual(repo.chats.map(\.isPinned), [true, false])
    }

    func testChatRemovedFromFolderDisappearsFromFolderOnly() async {
        repo.chats = [chat(1, order: 10), chat(2, order: 20)]
        showFolder7()
        service.chats = [chat(1, order: 10), chat(2, order: 20)]
        await repo.loadChats()
        XCTAssertEqual(repo.chats.map(\.id), [2, 1])

        repo.handleChatPositionUpdate(folderPosition(chat(1, order: 10), order: 0))

        XCTAssertEqual(repo.chats.map(\.id), [2])
        XCTAssertTrue(repo.store.isListed(1, in: .main), "Main still lists the chat")
    }

    func testChatAddedToDisplayedFolderByPositionAppears() async {
        showFolder7()
        service.chats = [chat(1, order: 10)]
        await repo.loadChats()

        repo.handleChatPositionUpdate(folderPosition(chat(3, order: 0), order: 50))

        XCTAssertEqual(repo.chats.map(\.id), [3, 1])
    }

    func testPositionInAnotherFolderDoesNotAppearInTheDisplayedOne() async {
        showFolder7()
        service.chats = [chat(1, order: 10)]
        await repo.loadChats()
        let widgetUpdates = widgetSync.updates.count

        repo.handleChatPositionUpdate(.init(
            chat: chat(3, order: 0),
            positions: [ChatListPosition(list: .folder(8), order: 50, isPinned: false)],
            source: .explicitPosition
        ))

        XCTAssertEqual(repo.chats.map(\.id), [1])
        XCTAssertEqual(widgetSync.updates.count, widgetUpdates, "nothing visible changed")
    }

    func testArchivedChatWithNewMessageStaysOutOfMain() async {
        repo.chats = [chat(1, order: 10)]
        // TDLib announced the chat in the archive only; getChat reports no Main order.
        repo.handleChatPositionUpdate(.init(
            chat: chat(9, order: 0),
            positions: [ChatListPosition(list: .archive, order: 5, isPinned: false)],
            source: .newChat
        ))
        service.chatsById[9] = chat(9, order: 0)

        repo.handleNewMessage(incoming(chatId: 9))
        await repo.missingChatFetchTask?.value

        XCTAssertEqual(service.getChatRequests, [9])
        XCTAssertEqual(repo.chats.map(\.id), [1])
    }

    func testRemovalInAnotherFolderPrunesThatFolderFile() {
        let folderId = Int64.random(in: 300_000...399_999)
        let file = repo.cache(for: folderId)
        defer { file.clear() }
        file.save([chat(1, order: 9), chat(2, order: 8)])
        file.flush()
        repo.chats = [chat(1, order: 9), chat(2, order: 8)]

        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 9),
            positions: [ChatListPosition(list: .folder(folderId), order: 0, isPinned: false)],
            source: .explicitPosition
        ))

        file.flush()
        XCTAssertEqual(file.load()?.map(\.id), [2], "a future launch must not restore the removed row")
        XCTAssertEqual(repo.chats.map(\.id), [1, 2], "Main is not the list that lost the chat")
    }

    // MARK: - Pages and snapshots

    func testCompleteMainPageRetiresRowsThatLeftMainWhileTheAppWasClosed() async {
        // Restored from disk: chat 2 was archived on the phone since.
        repo.chats = [chat(1, order: 90), chat(2, order: 80), chat(3, order: 70), chat(4, order: 60)]
        service.chats = [chat(1, order: 90), chat(3, order: 70)]

        await repo.loadChats()

        XCTAssertEqual(repo.chats.map(\.id), [1, 3, 4], "chat 4 ranks below the page, so nothing says it left")
        repo.chatListCache.flush()
        XCTAssertEqual(repo.chatListCache.load()?.map(\.id), [1, 3, 4], "a later launch must not restore chat 2")
    }

    func testIncompleteMainPageRetiresNothing() async {
        repo.chats = [chat(1, order: 90), chat(2, order: 80), chat(3, order: 70), chat(4, order: 60)]
        service.chats = [chat(1, order: 90), chat(3, order: 70)]
        service.getChatsPageIsComplete = false

        await repo.loadChats()

        XCTAssertEqual(repo.chats.map(\.id), [1, 2, 3, 4], "a lookup failed, so the page may lack chats it should list")
    }

    func testFirstPageAppliedAfterReadUpdateDoesNotRollBackUnread() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        service.chats = [chat(1, order: 10, unread: 5)]
        service.getChatsDelay = .milliseconds(200)
        let load = Task { await repo.loadChats() }
        await waitUntil { !service.getChatsRequests.isEmpty }

        // Read on another device while the page was on its way.
        repo.handleChatUpdate(chat(1, order: 10, unread: 0))
        await load.value

        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
    }

    func testPrefetchedPageDoesNotRollBackUnread() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.canLoadMoreChats = true
        repo.lastPaginationTime = .distantPast
        // The page was requested before the chat was read elsewhere.
        let requested = repo.store.revision
        repo.handleChatUpdate(chat(1, order: 10, unread: 0))
        repo.prefetchedChatPage = PrefetchedChatPage(
            folderId: nil, limit: AppConstants.Chat.loadLimit * 2, chats: [chat(1, order: 10, unread: 5)],
            isComplete: true, startedAtRevision: requested
        )

        await repo.loadMoreChats()

        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
        XCTAssertTrue(service.getChatsRequests.isEmpty, "the completed prefetch is consumed")
    }

    func testPrefetchStartedBeforeAnUpdateDoesNotRollItBack() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.isInitialSyncComplete = true
        repo.canLoadMoreChats = true
        service.chats = [chat(1, order: 10, unread: 5)]
        service.getChatsDelay = .milliseconds(200)
        repo.prepareNextChatPageIfNeeded()
        await waitUntil { !service.getChatsRequests.isEmpty }

        // Read on another device while the prefetch was on its way.
        repo.handleChatUpdate(chat(1, order: 10, unread: 0))
        await repo.loadMoreChats()

        XCTAssertEqual(service.getChatsRequests.count, 1, "loadMoreChats used the prefetch it waited for")
        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
    }

    func testPrefetchStartedAfterAnUpdateReplacesTheRecord() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.isInitialSyncComplete = true
        repo.canLoadMoreChats = true
        repo.handleChatUpdate(chat(1, order: 10, unread: 2))
        service.chats = [chat(1, order: 10, unread: 7)]
        repo.prepareNextChatPageIfNeeded()

        await repo.loadMoreChats()

        XCTAssertEqual(service.getChatsRequests.count, 1, "loadMoreChats used the prefetch")
        XCTAssertEqual(repo.chats.first?.unreadCount, 7, "the page is newer than the update")
    }

    func testLoadMoreRequestedBeforeAnUpdateDoesNotRollItBack() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.canLoadMoreChats = true
        service.chats = [chat(1, order: 10, unread: 5)]
        service.getChatsDelay = .milliseconds(200)
        let more = Task { await repo.loadMoreChats() }
        await waitUntil { !service.getChatsRequests.isEmpty }

        repo.handleChatUpdate(chat(1, order: 10, unread: 0))
        await more.value

        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
    }

    func testLoadMoreRequestedAfterAnUpdateReplacesTheRecord() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.canLoadMoreChats = true
        repo.handleChatUpdate(chat(1, order: 10, unread: 2))
        service.chats = [chat(1, order: 10, unread: 7)]

        await repo.loadMoreChats()

        XCTAssertEqual(repo.chats.first?.unreadCount, 7, "the page is newer than the update")
    }

    func testFirstPageRequestedAfterAnUpdateReplacesTheRecord() async {
        repo.chats = [chat(1, order: 10, unread: 5)]
        repo.handleChatUpdate(chat(1, order: 10, unread: 2))
        service.chats = [chat(1, order: 10, unread: 7)]

        await repo.loadChats()

        XCTAssertEqual(repo.chats.first?.unreadCount, 7, "the page is newer than the update")
    }

    func testMissingChatFetchDoesNotRollBackAnUpdateThatArrivedDuringIt() async {
        service.chatsById[9] = chat(9, order: 7, unread: 0)
        service.getChatDelay = .milliseconds(200)
        repo.handleNewMessage(incoming(chatId: 9))
        await waitUntil { !service.getChatRequests.isEmpty }

        repo.handleChatUpdate(chat(9, order: 0, unread: 3))
        await repo.missingChatFetchTask?.value

        XCTAssertEqual(repo.chat(id: 9)?.unreadCount, 3)
        XCTAssertEqual(repo.chats.map(\.id), [9], "the fetched row still enters the list")
    }

    func testMissingChatFetchRequestedAfterAnUpdateReplacesTheRecord() async {
        repo.handleChatUpdate(chat(9, order: 0, unread: 3))
        service.chatsById[9] = chat(9, order: 7, unread: 6)

        repo.handleNewMessage(incoming(chatId: 9))
        await repo.missingChatFetchTask?.value

        XCTAssertEqual(repo.chat(id: 9)?.unreadCount, 6, "the fetch is newer than the update")
    }

    func testDirectoryLookupDoesNotRollBackAnUpdateThatArrivedDuringIt() async {
        service.chatsById[5] = chat(5, order: 0, unread: 0)
        service.getChatDelay = .milliseconds(200)
        let lookup = Task { await repo.loadChatIfNeeded(5) }
        await waitUntil { !service.getChatRequests.isEmpty }

        repo.handleChatUpdate(chat(5, order: 0, unread: 3))
        await lookup.value

        XCTAssertEqual(repo.chat(id: 5)?.unreadCount, 3)
    }

    func testPageRowsKeepLocalDrafts() async {
        draftStore.setDraft(chatId: 1, text: "unsent")
        service.chats = [chat(1, order: 10), chat(2, order: 9)]

        await repo.loadChats()

        XCTAssertEqual(repo.chats.map(\.draftMessage), ["unsent", nil])
    }

    // MARK: - Updates

    func testFieldUpdateForUnlistedChatHasNoEffects() {
        repo.chats = [chat(1, order: 10)]
        let before = widgetSync.updates.count

        repo.handleChatUpdate(chat(99, order: 5, unread: 3))

        XCTAssertEqual(repo.chats.map(\.id), [1])
        XCTAssertEqual(widgetSync.updates.count, before, "the widget shows the list, not every known chat")
    }

    func testNewMessageReordersOnlyWhenTDLibReportsTheNewPosition() {
        repo.chats = [chat(1, order: 20), chat(2, order: 10)]

        repo.handleNewMessage(incoming(chatId: 2))

        XCTAssertEqual(repo.chats.first(where: { $0.id == 2 })?.lastMessage?.id, 500)
        XCTAssertEqual(repo.chats.map(\.id), [1, 2], "the order is TDLib's to give")

        // updateChatLastMessage follows updateNewMessage with the new vector.
        repo.handleChatPositionUpdate(.init(
            chat: chat(2, order: 30),
            positions: [ChatListPosition(list: .main, order: 30, isPinned: false)],
            source: .positionsReplacement
        ))

        XCTAssertEqual(repo.chats.map(\.id), [2, 1])
    }

    func testNewMessageForUnlistedKnownChatStillFetches() async {
        // TDLib announced the chat without a place in any list.
        repo.handleChatPositionUpdate(.init(chat: chat(9, order: 0), positions: [], source: .newChat))
        service.chatsById[9] = chat(9, order: 7)

        repo.handleNewMessage(incoming(chatId: 9))
        await repo.missingChatFetchTask?.value

        XCTAssertEqual(service.getChatRequests, [9])
        XCTAssertEqual(repo.chats.map(\.id), [9])
        XCTAssertEqual(repo.chats.first?.lastMessage?.id, 500)
    }

    // MARK: - Pin and mute

    func testPinAndMuteShowBeforeTheServiceAnswersAndRevertOnFailure() async {
        repo.chats = [chat(1, order: 10)]
        let pinGate = MockRequestGate()
        let muteGate = MockRequestGate()
        service.pinChatGate = pinGate
        service.muteChatGate = muteGate
        service.pinChatError = TestError.failed("offline")
        service.muteChatError = TestError.failed("offline")

        let pin = Task { try await repo.pinChat(chatId: 1, isPinned: true) }
        await waitUntil { pinGate.arrivals == 1 }
        XCTAssertEqual(repo.chats.first?.isPinned, true, "shown before the service answers")
        pinGate.open()
        let pinResult = await pin.result
        XCTAssertThrowsError(try pinResult.get())
        XCTAssertEqual(repo.chats.first?.isPinned, false)

        let mute = Task { try await repo.muteChat(chatId: 1, isMuted: true) }
        await waitUntil { muteGate.arrivals == 1 }
        XCTAssertEqual(repo.chats.first?.isMuted, true, "shown before the service answers")
        muteGate.open()
        let muteResult = await mute.result
        XCTAssertThrowsError(try muteResult.get())
        XCTAssertEqual(repo.chats.first?.isMuted, false)
    }

    // MARK: - Helpers

    private func showFolder7() {
        repo.folders = [ChatFolder(id: 7, title: "Work", iconName: "folder", chatIds: [])]
        repo.folderFilterEnabled = true
        repo.selectedFolderId = 7
    }

    private func chat(_ id: Int64, order: Int64, unread: Int = 0) -> ChatInfo {
        ChatInfo(
            id: id, title: "Chat \(id)", lastMessage: nil, unreadCount: unread,
            isGroup: false, isMuted: false, order: order
        )
    }

    private func folderPosition(_ chat: ChatInfo, order: Int64, pinned: Bool = false) -> ChatPositionUpdate {
        ChatPositionUpdate(
            chat: chat,
            positions: [ChatListPosition(list: .folder(7), order: order, isPinned: pinned)],
            source: .explicitPosition
        )
    }

    private func incoming(chatId: Int64) -> MessageInfo {
        MessageInfo(
            id: 500, chatId: chatId, senderName: "Bob", senderId: 2,
            content: .text("Hi"), date: Date(), isOutgoing: false, isRead: false
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
