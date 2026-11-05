import XCTest
@testable import OrbitextWatch

@MainActor
final class ChatRepositoryTests: XCTestCase {
    private var service: MockTelegramService!
    private var notificationManager: MockNotificationManager!
    private var widgetSync: MockWidgetSync!
    private var repo: ChatRepository!
    private var draftStore: DraftStore!
    private var preferences: AppPreferencesStore!

    override func setUp() async throws {
        service = MockTelegramService()
        notificationManager = MockNotificationManager()
        widgetSync = MockWidgetSync()
        draftStore = DraftStore()
        preferences = AppPreferencesStore(defaults: makeTestDefaults())
        repo = ChatRepository(
            service: service,
            draftStore: draftStore,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: preferences
        )
    }

    override func tearDown() async throws {
        // Cancels the draft writes a test left in flight: they hold the
        // repository until they finish.
        repo?.resetLoadedState()
        repo?.chatListCache.clear()
        repo = nil
        preferences = nil
        draftStore = nil
        widgetSync = nil
        notificationManager = nil
        service = nil
    }

    // MARK: - Account isolation

    func testResetRemovesFolderCachesWrittenByEarlierLaunches() throws {
        // An earlier launch, signed in to the previous account, left these on disk.
        let earlierLaunch = ListCache<ChatInfo>(filename: "cached_chats_folder_7.json")
        defer { earlierLaunch.clear() }
        earlierLaunch.save([
            ChatInfo(id: 42, title: "Previous account", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ])
        earlierLaunch.flush()
        let corruptBackup = FileManager.appSupportDirectory
            .appendingPathComponent("Orbitext", isDirectory: true)
            .appendingPathComponent("cached_chats.json.corrupt-account-test")
        try Data("{".utf8).write(to: corruptBackup)
        defer { try? FileManager.default.removeItem(at: corruptBackup) }

        repo.resetLoadedState()

        XCTAssertNil(ListCache<ChatInfo>(filename: "cached_chats_folder_7.json").load(),
                     "The next account would see the previous account's chats in folder 7")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptBackup.path))
    }

    // MARK: - Notifications decided on TDLib's state

    func testMessageInChatBeyondTheLoadedPageNotifies() async {
        repo.chats = [chat(1, "Alice")]
        repo.isInitialSyncComplete = true
        service.chatsById[25] = chat(25, "Bob")

        repo.handleNewMessage(incoming(chatId: 25))
        await waitUntil { !notificationManager.postedNotifications.isEmpty }

        XCTAssertEqual(notificationManager.postedNotifications.map(\.chatTitle), ["Bob"],
                       "Only the first page of chats could ever raise a notification")
        XCTAssertEqual(notificationManager.postedNotifications.first?.messageKey, "25:500")
    }

    func testFolderChatBeyondTheLoadedPageNotifies() async {
        selectFolder7(loadedPage: [chat(1, "Alice")])
        repo.folderListConfirmedByClient = 7
        service.chatsById[25] = chat(25, "Bob")
        service.chatFolderIdsByChatId[25] = [7]

        repo.handleNewMessage(incoming(chatId: 25))
        await waitUntil { !notificationManager.postedNotifications.isEmpty }

        XCTAssertEqual(notificationManager.postedNotifications.map(\.chatTitle), ["Bob"],
                       "A chat of the selected folder below its first page stayed silent")
    }

    func testChatOutsideTheSelectedFolderStaysQuiet() async {
        selectFolder7(loadedPage: [chat(1, "Alice")])
        repo.folderListConfirmedByClient = 7
        service.chatsById[55] = chat(55, "Shop") // TDLib places it in no folder

        repo.handleNewMessage(incoming(chatId: 55))

        await assertOnlyControlNotifies(controlInFolder: 7)
    }

    func testFolderDecisionWaitsForThisClientToReturnTheFolder() async {
        selectFolder7(loadedPage: [chat(1, "Alice")])
        service.chatsById[55] = chat(55, "Shop")

        // Cold start: the page came from the disk snapshot, not from TDLib.
        repo.handleNewMessage(incoming(chatId: 55))
        try? await Task.sleep(for: .milliseconds(50))
        repo.folderListConfirmedByClient = 7

        await assertOnlyControlNotifies(controlInFolder: 7)
    }

    func testFolderMembershipIsUnknownWhenTheFolderNeverConfirms() async {
        selectFolder7(loadedPage: [])
        repo.notificationFolderWait = .milliseconds(50)

        let membership = await repo.selectedFolderMembership(of: 55)

        XCTAssertNil(membership, "A restored snapshot is no proof that chat 55 is outside folder 7")
    }

    func testMessageAlreadyReadElsewhereStaysQuiet() async {
        repo.isInitialSyncComplete = true
        // A reconnect replays it before its read mark arrives.
        service.notificationStateByChatId[25] = ChatNotificationState(
            title: "Bob", isMuted: false, lastReadInboxMessageId: 500, folderIds: [])

        repo.handleNewMessage(incoming(chatId: 25))

        await assertOnlyControlNotifies()
    }

    func testChatMutedByItsTypeDefaultStaysQuiet() async {
        repo.isInitialSyncComplete = true
        // A group that uses the muted "Groups" default: its own mute_for is 0.
        service.notificationStateByChatId[25] = ChatNotificationState(
            title: "Group", isMuted: true, lastReadInboxMessageId: 0, folderIds: [])

        repo.handleNewMessage(incoming(chatId: 25))

        await assertOnlyControlNotifies()
    }

    func testPrefetchOfTheFolderConfirmsItForThisClient() async {
        // Cold start with a cached list: only the prefetch loads the folder.
        selectFolder7(loadedPage: [chat(1, "Alice")])

        repo.prepareNextChatPageIfNeeded()
        await waitUntil { repo.folderListConfirmedByClient == 7 }

        XCTAssertEqual(repo.folderListConfirmedByClient, 7,
                       "Chats outside the folder kept notifying for the whole first session")
    }

    func testChatLeftOpenInTheBackgroundStillNotifies() async {
        repo.isInitialSyncComplete = true
        service.chatsById[25] = chat(25, "Bob")
        notificationManager.activeChatId = 25
        // The wrist went down with the chat on screen.
        repo.isInBackgroundState = true

        repo.handleNewMessage(incoming(chatId: 25))
        await waitUntil { !notificationManager.postedNotifications.isEmpty }

        XCTAssertEqual(notificationManager.postedNotifications.map(\.chatTitle), ["Bob"])
    }

    func testForwardSavedToSavedMessagesStaysQuiet() async {
        repo.isInitialSyncComplete = true
        service.currentUserID = 900
        // TDLib reports a saved forward from someone else as incoming.

        repo.handleNewMessage(incoming(chatId: 900))

        await assertOnlyControlNotifies()
    }

    func testNotificationDecidedAfterLogoutIsNotShown() async {
        repo.isInitialSyncComplete = true
        service.chatsById[25] = chat(25, "Bob")
        service.notificationStateDelay = .milliseconds(150)

        repo.handleNewMessage(incoming(chatId: 25))
        // The account is reset while TDLib's answer for the old one is pending.
        repo.resetLoadedState()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(notificationManager.postedNotifications.isEmpty,
                      "A message of the signed-out account was announced after logout")
    }

    private func chat(_ id: Int64, _ title: String) -> ChatInfo {
        ChatInfo(id: id, title: title, lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
    }

    private func incoming(chatId: Int64) -> MessageInfo {
        MessageInfo(id: 500, chatId: chatId, senderName: "Bob", senderId: 2,
                    content: .text("Hi"), date: Date(), isOutgoing: false, isRead: false)
    }

    private func selectFolder7(loadedPage: [ChatInfo]) {
        repo.folders = [ChatFolder(id: 7, title: "Work", iconName: "folder", chatIds: [])]
        repo.folderFilterEnabled = true
        repo.selectedFolderId = 7
        repo.chats = loadedPage
        repo.loadedChatListFolderId = 7
        repo.isInitialSyncComplete = true
    }

    /// Sends a message that must notify after the one under test; once it
    /// arrives, the earlier decision has been made too.
    private func assertOnlyControlNotifies(controlInFolder folderId: Int64? = nil,
                                           file: StaticString = #filePath, line: UInt = #line) async {
        service.chatsById[77] = chat(77, "Control")
        if let folderId { service.chatFolderIdsByChatId[77] = [folderId] }
        repo.handleNewMessage(incoming(chatId: 77))
        await waitUntil { !notificationManager.postedNotifications.isEmpty }
        // Let a slower decision for the earlier message settle as well.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(notificationManager.postedNotifications.map(\.chatTitle), ["Control"], file: file, line: line)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHandleNewMessageUpdatesChat() {
        repo.chats = [
            ChatInfo(id: 1, title: "Test", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        let msg = MessageInfo(
            id: 100,
            chatId: 1,
            senderName: "Alice",
            senderId: 2,
            content: .text("Hello"),
            date: Date(),
            isOutgoing: false,
            isRead: false
        )
        repo.isInitialSyncComplete = false

        repo.handleNewMessage(msg)

        XCTAssertEqual(repo.chats.first?.lastMessage?.id, 100)
        XCTAssertEqual(repo.chats.first?.unreadCount, 1)
        XCTAssertEqual(widgetSync.updates.count, 1)
    }

    func testHandleDeleteMessagesClearsLastMessage() {
        let msg = MessageInfo(
            id: 42,
            chatId: 1,
            senderName: "Bob",
            senderId: 2,
            content: .text("Hi"),
            date: Date(),
            isOutgoing: false,
            isRead: false
        )
        repo.chats = [
            ChatInfo(id: 1, title: "Test", lastMessage: msg, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        repo.handleDeleteMessages(chatId: 1, messageIds: [42])

        XCTAssertNil(repo.chats.first?.lastMessage)
    }

    func testHandleTypingState() {
        repo.chats = [
            ChatInfo(id: 1, title: "Test", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        repo.handleTypingState(chatId: 1, names: ["Alice"])
        XCTAssertEqual(repo.chats.first?.typingUserNames, ["Alice"])

        repo.handleTypingState(chatId: 1, names: [])
        XCTAssertEqual(repo.chats.first?.typingUserNames, [])
    }

    func testLoadChatsMarksLaunchAndSyncsWidget() async {
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.loadChats()

        XCTAssertEqual(repo.chats.count, 1)
        XCTAssertEqual(repo.chatListLoadingState, .idle)
        XCTAssertTrue(notificationManager.hasLaunchedBefore)
        XCTAssertEqual(widgetSync.updates.last?.chatCount, 1)
    }

    func testLoadChatsUsesInitialLoadingStateForEmptyUnsyncedList() async {
        service.getChatsDelay = .seconds(1)
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        let task = Task { await repo.loadChats() }
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(repo.chatListLoadingState, .initial)

        await task.value
        XCTAssertEqual(repo.chatListLoadingState, .idle)
    }

    func testLoadChatsUsesInitialLoadingStateForEmptySyncedRecovery() async {
        service.getChatsDelay = .seconds(1)
        repo.isInitialSyncComplete = true
        service.chats = [
            ChatInfo(id: 1, title: "Recovered", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        let task = Task { await repo.loadChats() }
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(repo.chatListLoadingState, .initial)

        await task.value
        XCTAssertEqual(repo.chatListLoadingState, .idle)
    }

    func testLoadChatsUsesRefreshLoadingStateForExistingList() async {
        service.getChatsDelay = .seconds(1)
        repo.chats = [
            ChatInfo(id: 1, title: "Cached", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        repo.isInitialSyncComplete = true
        service.chats = repo.chats

        let task = Task { await repo.loadChats() }
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(repo.chatListLoadingState, .refresh)

        await task.value
        XCTAssertEqual(repo.chatListLoadingState, .idle)
    }

    func testLoadChatsRestoresFolderCacheBeforeNetworkCompletes() async {
        let folderId = Int64.random(in: 10_000...99_999)
        let folderCache = repo.cache(for: folderId)
        defer { folderCache.clear() }
        folderCache.save([
            ChatInfo(id: 10, title: "Cached Folder Chat", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: 10)
        ])
        folderCache.flush()

        repo.chats = [
            ChatInfo(id: 1, title: "Main Chat", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        repo.loadedChatListFolderId = nil
        repo.folderFilterEnabled = true
        repo.folders = [ChatFolder(id: folderId, title: "Folder", iconName: "folder", chatIds: [])]
        repo.selectedFolderId = folderId
        service.getChatsDelay = .seconds(1)
        service.chats = [
            ChatInfo(id: 11, title: "Fresh Folder Chat", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: 11)
        ]

        let task = Task { await repo.loadChats() }
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(repo.chats.map(\.title), ["Cached Folder Chat"])
        XCTAssertEqual(repo.loadedChatListFolderId, folderId)

        await task.value
        XCTAssertEqual(repo.chats.map(\.title), ["Fresh Folder Chat"])
        XCTAssertEqual(repo.loadedChatListFolderId, folderId)
    }

    func testLoadChatsKeepsCachedFolderRowsWhenRefreshReturnsShortPage() async {
        let folderId = Int64.random(in: 100_000...199_999)
        let folderCache = repo.cache(for: folderId)
        defer { folderCache.clear() }
        folderCache.save((1...3).map {
            ChatInfo(id: Int64($0), title: "Cached \($0)", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: Int64(10 - $0))
        })
        folderCache.flush()

        repo.folderFilterEnabled = true
        repo.folders = [ChatFolder(id: folderId, title: "Folder", iconName: "folder", chatIds: [])]
        repo.selectedFolderId = folderId
        service.chats = [
            ChatInfo(id: 1, title: "Fresh 1", lastMessage: nil, unreadCount: 1, isGroup: true, isMuted: false, order: 9),
            ChatInfo(id: 2, title: "Fresh 2", lastMessage: nil, unreadCount: 2, isGroup: true, isMuted: false, order: 8)
        ]

        await repo.loadChats()

        XCTAssertEqual(repo.chats.map(\.id), [1, 2, 3])
        XCTAssertEqual(repo.chats[0].title, "Fresh 1")
        XCTAssertEqual(repo.chats[1].title, "Fresh 2")
        XCTAssertEqual(repo.chats[2].title, "Cached 3")
        XCTAssertTrue(repo.canLoadMoreChats)
    }

    func testLoadMoreChatsUsesPaginationLoadingState() async {
        service.getChatsDelay = .seconds(1)
        service.chats = (1...25).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }
        repo.chats = Array(service.chats.prefix(10))
        repo.canLoadMoreChats = true
        repo.lastPaginationTime = .distantPast

        let task = Task { await repo.loadMoreChats() }
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(repo.chatListLoadingState, .pagination)

        await task.value
        XCTAssertEqual(repo.chatListLoadingState, .idle)
    }

    func testLoadMoreChatsPersistsExpandedChatCache() async throws {
        repo.chatListCache.clear()
        defer { repo.chatListCache.clear() }
        service.chats = (1...25).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }

        await repo.loadChats()
        repo.lastPaginationTime = .distantPast
        await repo.loadMoreChats()
        guard try await waitForAutomaticChatCacheSave("expanded chat page", matching: {
            $0.count == 20 && $0.last?.id == 20
        }) else { return }

        let restored = ChatRepository(
            service: service,
            draftStore: draftStore,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: preferences
        )

        XCTAssertEqual(repo.chats.count, 20)
        XCTAssertEqual(restored.chats.count, 20)
        XCTAssertEqual(restored.chats.last?.id, 20)
    }

    func testLoadMoreChatsReconcilesMissingLoadedChats() async {
        service.chats = (1...25).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }
        repo.chats = Array(service.chats.prefix(10)).filter { $0.id != 5 }
        repo.canLoadMoreChats = true
        repo.lastPaginationTime = .distantPast

        await repo.loadMoreChats()

        XCTAssertEqual(repo.chats.map(\.id), Array(1...20).map(Int64.init))
        XCTAssertEqual(repo.chats.count, 20)
        XCTAssertTrue(repo.canLoadMoreChats)
    }

    /// Since ab0cbdd ("Stabilize chat list loading row") a page that does
    /// not grow marks the list exhausted so the loading row disappears
    /// instead of spinning forever.
    func testLoadMoreChatsMarksListExhaustedWhenPageDoesNotGrow() async {
        service.chats = (1...10).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }
        repo.chats = service.chats
        repo.canLoadMoreChats = true
        repo.lastPaginationTime = .distantPast

        await repo.loadMoreChats()

        XCTAssertEqual(repo.chats.map(\.id), Array(1...10).map(Int64.init))
        XCTAssertEqual(repo.chatListLoadingState, .idle)
        XCTAssertFalse(repo.canLoadMoreChats)
    }

    func testLoadMoreChatsDoesNotRetryAfterExhaustedPage() async {
        service.chats = (1...10).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }
        repo.chats = service.chats
        repo.canLoadMoreChats = true
        repo.lastPaginationTime = .distantPast

        await repo.loadMoreChats()
        repo.lastPaginationTime = .distantPast
        await repo.loadMoreChats()

        XCTAssertEqual(service.getChatsRequests.map(\.limit), [20])
        XCTAssertFalse(repo.canLoadMoreChats)
        XCTAssertEqual(repo.chatListLoadingState, .idle)
    }

    func testPrepareNextChatPageTracksPreparingAndStoresCompletedPage() async {
        service.getChatsDelay = .seconds(1)
        service.chats = (1...25).map {
            ChatInfo(
                id: Int64($0),
                title: "Chat \($0)",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: Int64(100 - $0)
            )
        }
        repo.chats = Array(service.chats.prefix(10))
        repo.isInitialSyncComplete = true
        repo.canLoadMoreChats = true
        repo.chatLoadLimit = 10

        repo.prepareNextChatPageIfNeeded()
        for _ in 0..<100 where service.getChatsRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(repo.isPreparingNextChatPage)
        let task = repo.chatListPrefetchTask
        _ = await task?.value

        XCTAssertFalse(repo.isPreparingNextChatPage)
        XCTAssertNil(repo.chatListPrefetchTask)
        XCTAssertEqual(repo.prefetchedChatPage?.limit, 20)
        XCTAssertEqual(repo.prefetchedChatPage?.chats.count, 20)
    }

    func testChatListLoadMoreFooterState() {
        XCTAssertEqual(
            ChatListLoadMoreFooterState(canLoadMore: true, sectionsAreEmpty: false, loadingState: .idle),
            .button
        )
        XCTAssertEqual(
            ChatListLoadMoreFooterState(canLoadMore: true, sectionsAreEmpty: false, loadingState: .pagination),
            .loading
        )
        XCTAssertEqual(
            ChatListLoadMoreFooterState(canLoadMore: false, sectionsAreEmpty: false, loadingState: .pagination),
            .loading
        )
        XCTAssertEqual(
            ChatListLoadMoreFooterState(canLoadMore: true, sectionsAreEmpty: false, loadingState: .idle, isPreparingNextPage: true),
            .loading
        )
        XCTAssertEqual(
            ChatListLoadMoreFooterState(canLoadMore: true, sectionsAreEmpty: true, loadingState: .idle),
            .hidden
        )
    }

    func testChatListEmptyStateTreatsIncompleteInitialSyncAsLoading() {
        XCTAssertEqual(
            ChatListEmptyState(sectionsAreEmpty: true, initialSyncComplete: false, loadingState: .idle),
            .loading
        )
        XCTAssertEqual(
            ChatListEmptyState(sectionsAreEmpty: true, initialSyncComplete: false, loadingState: .initial),
            .loading
        )
        XCTAssertEqual(
            ChatListEmptyState(sectionsAreEmpty: true, initialSyncComplete: true, loadingState: .idle),
            .empty
        )
        XCTAssertEqual(
            ChatListEmptyState(sectionsAreEmpty: false, initialSyncComplete: false, loadingState: .idle),
            .hidden
        )
    }

    func testHandleNewMessagePersistsChatCacheWithoutTransientState() async throws {
        repo.chatListCache.clear()
        defer { repo.chatListCache.clear() }
        repo.chats = [
            ChatInfo(
                id: 1,
                title: "Alice",
                lastMessage: nil,
                unreadCount: 0,
                isGroup: false,
                isMuted: false,
                order: 1,
                typingUserNames: ["Bob"],
                isOnline: true
            )
        ]

        let msg = MessageInfo(
            id: 100,
            chatId: 1,
            senderName: "Alice",
            senderId: 2,
            content: .text("Hello"),
            date: Date(),
            isOutgoing: false,
            isRead: false
        )
        repo.handleNewMessage(msg)
        guard try await waitForAutomaticChatCacheSave("new message", matching: {
            $0.first?.lastMessage?.id == msg.id
        }) else { return }

        let restored = ChatRepository(
            service: service,
            draftStore: draftStore,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: preferences
        )

        XCTAssertEqual(restored.chats.first?.lastMessage?.id, 100)
        XCTAssertEqual(restored.chats.first?.unreadCount, 1)
        XCTAssertEqual(restored.chats.first?.typingUserNames, [])
        XCTAssertEqual(restored.chats.first?.isOnline, false)
    }

    private func waitForAutomaticChatCacheSave(
        _ description: String,
        matching predicate: ([ChatInfo]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))

        // Observe the normal debounced disk write without triggering flush().
        // A fixed sleep cannot guarantee that the utility queue has finished.
        while true {
            try Task.checkCancellation()
            if let cached = repo.chatListCache.load(), predicate(cached) {
                return true
            }
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for automatic chat-cache persistence: \(description)", file: file, line: line)
                return false
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testSaveDraftUpdatesChatAndStore() {
        repo.chats = [
            ChatInfo(id: 1, title: "Test", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        repo.saveDraft(chatId: 1, text: "Hello")

        XCTAssertEqual(repo.chats.first?.draftMessage, "Hello")
        XCTAssertEqual(draftStore.getDraft(chatId: 1), "Hello")
    }

    /// The request for an older draft is in flight, cannot be called back,
    /// and is slow: the newer draft goes out only after it finished.
    func testNewerDraftIsSentAfterAnOlderOneStillInFlight() async {
        service.setDraftIgnoresCancellation = true
        service.setDraftDelay = { $0 == "old" ? .milliseconds(150) : .zero }

        repo.saveDraft(chatId: 1, text: "old")
        await waitUntil { service.setDraftCalls.count == 1 }
        repo.saveDraft(chatId: 1, text: "new")
        await waitUntil { service.setDraftCompletions.count == 2 }

        XCTAssertEqual(service.setDraftCalls.map(\.text), ["old", "new"])
        XCTAssertEqual(service.setDraftCompletions, ["old", "new"])
        XCTAssertEqual(service.drafts[1], "new")
    }

    /// An older draft that has not started when the newer one comes is not
    /// sent at all.
    func testBackToBackDraftsSendOnlyTheLastOne() async {
        repo.saveDraft(chatId: 1, text: "old")
        repo.saveDraft(chatId: 1, text: "new")
        await waitUntil { service.setDraftCompletions.count == 1 }

        XCTAssertEqual(service.setDraftCalls.map(\.text), ["new"])
        XCTAssertEqual(service.drafts[1], "new")
    }

    func testDraftsOfDifferentChatsDoNotWaitForEachOther() async {
        service.setDraftDelay = { $0 == "slow" ? .seconds(5) : .zero }

        repo.saveDraft(chatId: 1, text: "slow")
        repo.saveDraft(chatId: 2, text: "fast")
        await waitUntil { service.drafts[2] == "fast" }

        XCTAssertEqual(service.drafts[2], "fast")
        XCTAssertNil(service.drafts[1])
    }

    /// Each chat whose composer appeared left its finished write behind until
    /// sign-out.
    func testFinishedDraftWriteLeavesNothingBehind() async {
        repo.saveDraft(chatId: 1, text: "done")
        repo.saveDraft(chatId: 2, text: "also done")

        await waitUntil { repo.draftSyncTasks.isEmpty }

        XCTAssertEqual(service.drafts[1], "done")
        XCTAssertEqual(service.drafts[2], "also done")
        XCTAssertTrue(repo.draftSyncTasks.isEmpty)
    }

    /// The older write is what the newer one waits for. When it finishes it
    /// must leave the newer one's entry alone, or the next draft would not
    /// wait for the newer write.
    func testFinishedOlderDraftWriteKeepsTheNewerOnesEntry() async {
        service.setDraftIgnoresCancellation = true
        service.setDraftDelay = { $0 == "old" ? .milliseconds(100) : .milliseconds(400) }
        repo.saveDraft(chatId: 1, text: "old")
        await waitUntil { service.setDraftCalls.count == 1 }
        repo.saveDraft(chatId: 1, text: "new")
        // The newer write starts when the older one has finished.
        await waitUntil { service.setDraftCalls.count == 2 }

        XCTAssertEqual(service.setDraftCompletions, ["old"])
        XCTAssertNotNil(repo.draftSyncTasks[1], "The newer write is still in flight")

        await waitUntil { service.setDraftCompletions.count == 2 }
        await waitUntil { repo.draftSyncTasks.isEmpty }
        XCTAssertTrue(repo.draftSyncTasks.isEmpty)
    }

    func testResetCancelsDraftWritesStillPending() async throws {
        service.setDraftDelay = { _ in .milliseconds(150) }
        repo.saveDraft(chatId: 1, text: "late")

        repo.resetLoadedState()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertNil(service.drafts[1], "A draft write outlived the sign-out")
    }

    func testListCacheFlushWritesPendingSaveImmediately() {
        let cache = ListCache<String>(filename: "listcache-flush-\(UUID().uuidString).json")
        defer { cache.clear() }

        cache.save(["latest"])
        cache.flush()

        XCTAssertEqual(cache.load(), ["latest"])
    }

    func testListCachePreservesCorruptStoreBeforeNewWrites() throws {
        let filename = "listcache-corrupt-\(UUID().uuidString).json"
        let dir = FileManager.appSupportDirectory
            .appendingPathComponent("Orbitext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(filename)
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            if let backups = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for backup in backups where backup.lastPathComponent.hasPrefix("\(filename).corrupt-") {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
        }

        let cache = ListCache<String>(filename: filename)

        XCTAssertNil(cache.load())
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(filename).corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        cache.save(["after corruption"])
        cache.flush()

        XCTAssertEqual(cache.load(), ["after corruption"])
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
    }
}
