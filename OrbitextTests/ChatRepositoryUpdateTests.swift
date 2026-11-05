import XCTest
@testable import OrbitextWatch

@MainActor
final class ChatRepositoryUpdateTests: XCTestCase {
    private var service: MockTelegramService!
    private var notificationManager: MockNotificationManager!
    private var widgetSync: MockWidgetSync!
    private var repo: ChatRepository!

    override func setUp() async throws {
        service = MockTelegramService()
        notificationManager = MockNotificationManager()
        widgetSync = MockWidgetSync()
        repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
    }

    func testWidgetSkipsReadChatBootstrapAndNonWidgetChanges() {
        let defaults = makeTestDefaults()
        var reloads = 0
        let sync = WidgetSyncService(defaults: defaults, reloadTimelines: { reloads += 1 })
        var chats: [ChatInfo] = []
        sync.update(chats: chats, isInBackground: false)

        for id in Int64(1)...Int64(200) {
            chats.append(ChatInfo(
                id: id, title: "Chat \(id)", lastMessage: nil, unreadCount: 0,
                isGroup: false, isMuted: false, order: id
            ))
            sync.update(chats: chats, isInBackground: false)
        }
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(defaults.integer(forKey: "totalUnread"), 0)

        chats[0].unreadCount = 1
        sync.update(chats: chats, isInBackground: false)
        XCTAssertEqual(reloads, 2)
        chats[0].isOnline = true
        chats[0].photoFileId = "updated-photo"
        chats[0].typingUserNames = ["Someone"]
        sync.update(chats: chats, isInBackground: true)
        XCTAssertEqual(reloads, 2)

        // A replacement service should also recognize persisted content.
        let relaunched = WidgetSyncService(defaults: defaults, reloadTimelines: { reloads += 1 })
        relaunched.update(chats: chats, isInBackground: false)
        XCTAssertEqual(reloads, 2)
    }

    func testWidgetRefreshesPreviewEditsTopChatChangesAndClearsReadState() {
        let defaults = makeTestDefaults()
        var reloads = 0
        let sync = WidgetSyncService(defaults: defaults, reloadTimelines: { reloads += 1 })
        var first = ChatInfo(
            id: -1_001_234_567_890, title: "First", lastMessage: MessageInfo(
                id: 9, chatId: -1_001_234_567_890, senderName: "Alice", senderId: 1,
                content: .text(FormattedString(text: "Before")), date: .distantPast,
                isOutgoing: false, isRead: false
            ), unreadCount: 1, isGroup: true, isMuted: false, order: 2
        )
        let second = ChatInfo(
            id: 2, title: "Second", lastMessage: nil, unreadCount: 1,
            isGroup: false, isMuted: false, order: 1
        )
        sync.update(chats: [first, second], isInBackground: false)
        XCTAssertEqual(defaults.object(forKey: "lastChatId") as? Int64, first.id)
        XCTAssertEqual(reloads, 1)

        first.lastMessage?.content = .text(FormattedString(text: "After"))
        sync.update(chats: [first, second], isInBackground: false)
        XCTAssertEqual(defaults.string(forKey: "lastMessagePreview"), "After")
        XCTAssertEqual(reloads, 2)

        first.title = "Renamed"
        sync.update(chats: [first, second], isInBackground: false)
        XCTAssertEqual(defaults.string(forKey: "lastChatName"), "Renamed")
        XCTAssertEqual(reloads, 3)

        sync.update(chats: [second, first], isInBackground: false)
        XCTAssertEqual(defaults.object(forKey: "lastChatId") as? Int64, second.id)
        XCTAssertNil(defaults.object(forKey: "lastMessagePreview"))
        XCTAssertEqual(reloads, 4)

        sync.update(chats: [], isInBackground: true)
        XCTAssertEqual(defaults.integer(forKey: "totalUnread"), 0)
        for key in ["lastChatName", "lastMessagePreview", "lastChatId"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        XCTAssertEqual(reloads, 5)
        sync.update(chats: [], isInBackground: true)
        XCTAssertEqual(reloads, 5)
    }

    func testWidgetDoesNotReloadWhenAppGroupDefaultsUnavailable() {
        var reloads = 0
        WidgetSyncService(defaults: nil, reloadTimelines: { reloads += 1 })
            .update(chats: [], isInBackground: false)
        XCTAssertEqual(reloads, 0)
    }

    // MARK: - handleChatUpdate preserves local state

    func testHandleChatUpdatePreservesTypingUserNames() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: 1)
        ]

        // Set typing state
        repo.handleTypingState(chatId: 1, names: ["Bob", "Carol"])
        XCTAssertEqual(repo.chats.first?.typingUserNames, ["Bob", "Carol"])

        // Chat update from TDLib (no typing info in cache)
        let updated = ChatInfo(id: 1, title: "Alice Updated", lastMessage: nil, unreadCount: 2, isGroup: true, isMuted: false, order: 1)
        repo.handleChatUpdate(updated)

        // Title should update, typing should be preserved
        XCTAssertEqual(repo.chats.first?.title, "Alice Updated")
        XCTAssertEqual(repo.chats.first?.unreadCount, 2)
        XCTAssertEqual(repo.chats.first?.typingUserNames, ["Bob", "Carol"])
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 2)
    }

    func testTypingIndicatorExpiresWhenTheRemoteClientGoesSilent() async {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: 1)
        ]
        repo.typingExpiry = .milliseconds(60)
        repo.typingExpiryTick = .milliseconds(10)

        // The remote client crashes mid-action and never sends the cancel.
        repo.handleChatAction(chatId: 1, names: ["Bob"], kind: .recordingVoice)
        XCTAssertEqual(repo.chats.first?.typingUserNames, ["Bob"])
        let deadline = ContinuousClock.now + .seconds(2)
        while repo.chats.first?.typingUserNames.isEmpty == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(repo.chats.first?.typingUserNames, [], "a ghost indicator stayed in the list")
        XCTAssertEqual(repo.chats.first?.typingActionKind, ChatActionKind.none)
        XCTAssertTrue(repo.typingExpiryByChat.isEmpty)
    }

    func testExplicitMainPositionUpdateRemovesChatWhenOrderBecomesZero() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 10),
            ChatInfo(id: 2, title: "Bob", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 9)
        ]

        repo.handleChatPositionUpdate(.init(
            chat: ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 0),
            positions: [ChatListPosition(list: .main, order: 0, isPinned: false)],
            source: .explicitPosition
        ))

        XCTAssertEqual(repo.chats.map(\.id), [2])
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 1)
    }

    func testHandleChatUpdateKeepsZeroOrderChatWhileListIsLoading() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 10),
            ChatInfo(id: 2, title: "Bob", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 9)
        ]
        repo.isLoadingMoreChats = true

        repo.handleChatUpdate(
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 0)
        )

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.first?.order, 10)
    }

    func testHandleChatUpdateKeepsZeroOrderChatDuringInitialLoad() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 10),
            ChatInfo(id: 2, title: "Bob", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 9)
        ]
        repo.chatListLoadingState = .initial

        repo.handleChatUpdate(
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 0)
        )

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.first?.order, 10)
    }

    func testHandleChatUpdateKeepsZeroOrderChatDuringRefresh() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 10),
            ChatInfo(id: 2, title: "Bob", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 9)
        ]
        repo.chatListLoadingState = .refresh

        repo.handleChatUpdate(
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 0)
        )

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.first?.order, 10)
    }

    func testHandleChatUpdateKeepsZeroOrderChatWhileFolderFilterIsActive() {
        repo.folders = [
            ChatFolder(id: 7, title: "Groups", iconName: "folder", chatIds: [1, 2])
        ]
        repo.folderFilterEnabled = true
        repo.selectedFolderId = 7
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: true, isMuted: false, order: 10),
            ChatInfo(id: 2, title: "Bob", lastMessage: nil, unreadCount: 1, isGroup: true, isMuted: false, order: 9)
        ]

        repo.handleChatUpdate(
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: true, isMuted: false, order: 0)
        )

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.first?.order, 10)
    }

    func testMarkAsReadSyncsWidgetUnreadCount() async {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markAsRead(chatId: 1, messageId: 100)

        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 0)
    }

    func testMarkAsReadPreservesUnreadCountWhenServiceFails() async {
        service.markAsReadError = TestError.failed("network down")
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 3, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markAsRead(chatId: 1, messageId: 100)

        XCTAssertEqual(repo.chats.first?.unreadCount, 3)
        XCTAssertTrue(widgetSync.updates.isEmpty)
    }

    // MARK: - handleNewMessage suppresses notification when viewing chat

    func testHandleNewMessageSuppressesNotificationForActiveChat() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        repo.isInitialSyncComplete = true
        notificationManager.hasLaunchedBefore = true
        notificationManager.isAuthorized = true
        notificationManager.activeChatId = 1 // User is viewing this chat

        let msg = MessageInfo(
            id: 100, chatId: 1, senderName: "Alice", senderId: 2,
            content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false
        )
        repo.handleNewMessage(msg)

        // Unread count still increments (server reconciles)
        XCTAssertEqual(repo.chats.first?.unreadCount, 1)
        // But no notification posted
        XCTAssertTrue(notificationManager.postedNotifications.isEmpty,
            "Should not post notification for active chat")
    }

    func testHandleNewMessagePostsNotificationForInactiveChat() async {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        repo.isInitialSyncComplete = true
        notificationManager.hasLaunchedBefore = true
        notificationManager.isAuthorized = true
        notificationManager.activeChatId = 999 // Viewing a different chat

        let msg = MessageInfo(
            id: 100, chatId: 1, senderName: "Alice", senderId: 2,
            content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false
        )
        repo.handleNewMessage(msg)
        await waitForPostedNotification()

        XCTAssertEqual(notificationManager.postedNotifications.count, 1)
        XCTAssertEqual(notificationManager.postedNotifications.first?.chatTitle, "Alice")
    }

    func testNotificationNamesSpoilerInsteadOfShowingIt() async {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        repo.isInitialSyncComplete = true
        notificationManager.hasLaunchedBefore = true
        notificationManager.isAuthorized = true
        notificationManager.activeChatId = 999
        let secret = FormattedString(text: "Code 1234", entities: [.spoiler(offset: 5, length: 4)])

        repo.handleNewMessage(MessageInfo(
            id: 100, chatId: 1, senderName: "Alice", senderId: 2,
            content: .text(secret), date: Date(), isOutgoing: false, isRead: false
        ))
        await waitForPostedNotification()

        XCTAssertEqual(notificationManager.postedNotifications.first?.preview, "Code \(L10n.string("Spoiler"))",
                       "The notification reveals the spoiler or makes VoiceOver read mask glyphs")
    }

    /// Notification decisions read TDLib's state asynchronously.
    private func waitForPostedNotification() async {
        let deadline = ContinuousClock.now + .seconds(1)
        while notificationManager.postedNotifications.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHandleNewMessageSkipsNotificationForMutedChat() {
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: true, order: 1)
        ]
        repo.isInitialSyncComplete = true
        notificationManager.hasLaunchedBefore = true

        let msg = MessageInfo(
            id: 100, chatId: 1, senderName: "Alice", senderId: 2,
            content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false
        )
        repo.handleNewMessage(msg)

        XCTAssertTrue(notificationManager.postedNotifications.isEmpty)
    }

    // MARK: - Chats the list lacks

    func testHandleNewMessageForMissingChatSkippedWhenFolderFilterEnabled() {
        repo.folderFilterEnabled = true
        repo.chats = []

        let msg = MessageInfo(
            id: 100, chatId: 999, senderName: "Unknown", senderId: 2,
            content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false
        )
        repo.handleNewMessage(msg)

        // Should not add the chat when folder filter is on
        XCTAssertTrue(repo.chats.isEmpty)
    }

    func testResetLoadedStatePreventsInFlightMissingChatUpsert() async {
        service.getChatDelay = .seconds(1)
        service.chatsById[999] = ChatInfo(
            id: 999,
            title: "Late chat",
            lastMessage: nil,
            unreadCount: 0,
            isGroup: false,
            isMuted: false,
            order: 1
        )

        let msg = MessageInfo(
            id: 100, chatId: 999, senderName: "Unknown", senderId: 2,
            content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false
        )
        repo.handleNewMessage(msg)

        for _ in 0..<100 where service.getChatRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.getChatRequests, [999])

        repo.resetLoadedState()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(repo.chats.isEmpty)
        XCTAssertTrue(widgetSync.updates.isEmpty)
    }
}
