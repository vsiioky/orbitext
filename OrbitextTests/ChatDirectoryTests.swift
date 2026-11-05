import Observation
import XCTest
@testable import OrbitextWatch

/// The directory knows every chat TDLib announced, not only the ones in the
/// list on screen.
@MainActor
final class ChatDirectoryTests: XCTestCase {
    private var service: MockTelegramService!
    private var repo: ChatRepository!

    override func setUp() async throws {
        ListCache<ChatInfo>(filename: "cached_chats.json").clear()
        service = MockTelegramService()
        repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
    }

    override func tearDown() async throws {
        repo?.chatListCache.clear()
        repo = nil
        service = nil
    }

    func testUpdatesForChatsBeyondThePageReachTheDirectory() {
        repo.chats = [chat(1, order: 10)]
        // TDLib announces chats far beyond the loaded page, then keeps them current.
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0, title: "Far"), positions: [], source: .newChat))
        repo.handleChatUpdate(chat(50, order: 0, title: "Renamed", unread: 4))

        XCTAssertEqual(repo.chat(id: 50)?.title, "Renamed")
        XCTAssertEqual(repo.chat(id: 50)?.unreadCount, 4)
        XCTAssertEqual(repo.chats.map(\.id), [1], "the list on screen is unchanged")
        XCTAssertNil(repo.chat(id: 51))
    }

    func testChatLookupTakesTheDisplayedListsOrderAndPin() {
        repo.chats = [chat(1, order: 10)]
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 10),
            positions: [ChatListPosition(list: .folder(7), order: 90, isPinned: true)],
            source: .explicitPosition
        ))

        XCTAssertEqual(repo.chat(id: 1)?.order, 10)
        XCTAssertEqual(repo.chat(id: 1)?.isPinned, false)

        repo.loadedChatListFolderId = 7
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 10),
            positions: [ChatListPosition(list: .folder(7), order: 90, isPinned: true)],
            source: .explicitPosition
        ))

        XCTAssertEqual(repo.chat(id: 1)?.order, 90)
        XCTAssertEqual(repo.chat(id: 1)?.isPinned, true)
    }

    func testChatLookupIsObservable() {
        repo.chats = [chat(1, order: 10)]
        let changed = ObservationFlag()

        withObservationTracking {
            _ = repo.chat(id: 50)
        } onChange: {
            changed.raise()
        }
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0), positions: [], source: .newChat))

        XCTAssertTrue(changed.isRaised, "a view showing chat 50 must redraw when it is announced")
    }

    func testListOnScreenIsObservable() {
        repo.chats = [chat(1, order: 10)]
        let changed = ObservationFlag()

        withObservationTracking {
            _ = repo.chats
        } onChange: {
            changed.raise()
        }
        repo.handleChatUpdate(chat(1, order: 10, title: "Renamed"))

        XCTAssertTrue(changed.isRaised)
    }

    func testListOnScreenIsNotInvalidatedByUnrelatedChats() {
        repo.chats = [chat(1, order: 10)]
        let changed = ObservationFlag()

        withObservationTracking {
            _ = repo.chats
        } onChange: {
            changed.raise()
        }
        repo.handleChatUpdate(chat(99, order: 0, title: "Elsewhere"))

        XCTAssertFalse(changed.isRaised, "an update for a chat that is not listed redraws nothing")
    }

    func testChatLookupIsNotInvalidatedByAFieldUpdateThatChangesNothing() {
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0, title: "Same"), positions: [], source: .newChat))
        let changed = ObservationFlag()

        withObservationTracking {
            _ = repo.chat(id: 50)
        } onChange: {
            changed.raise()
        }
        // TDLib repeats fields it has not changed, for example a contact's
        // online status for a chat that is not listed.
        repo.handleChatUpdate(chat(50, order: 0, title: "Same"))
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0, title: "Same"), positions: [], source: .newChat))

        XCTAssertFalse(changed.isRaised, "a view showing chat 50 has nothing new to draw")
    }

    func testChatLookupIsInvalidatedWhenOnlyTheLastMessageTextChanges() {
        var edited = chat(50, order: 0)
        edited.lastMessage = message(id: 7, text: "Before")
        repo.handleChatUpdate(edited)
        let changed = ObservationFlag()

        withObservationTracking {
            _ = repo.chat(id: 50)
        } onChange: {
            changed.raise()
        }
        edited.lastMessage = message(id: 7, text: "After")
        repo.handleChatUpdate(edited)

        XCTAssertTrue(changed.isRaised, "an edit keeps the message id, and the preview shows its text")
        XCTAssertEqual(repo.chat(id: 50)?.lastMessage?.content.textPreview, "After")
    }

    // MARK: - Lookups that used to need the chat on the loaded page

    func testLoadChatIfNeededFillsDirectoryWithoutListingIt() async {
        repo.chats = [chat(1, order: 10)]
        service.chatsById[77] = chat(77, order: 5, title: "Support")

        await repo.loadChatIfNeeded(77)

        XCTAssertEqual(repo.chat(id: 77)?.title, "Support")
        XCTAssertEqual(repo.chats.map(\.id), [1], "looking a chat up does not put it into the list")
        XCTAssertFalse(repo.store.isListed(77, in: .main))
    }

    func testLoadChatIfNeededSkipsChatsTheDirectoryKnows() async {
        repo.chats = [chat(1, order: 10)]

        await repo.loadChatIfNeeded(1)

        XCTAssertTrue(service.getChatRequests.isEmpty)
    }

    func testLoadChatIfNeededIgnoresAnAnswerThatArrivesAfterReset() async {
        service.chatsById[77] = chat(77, order: 5, title: "Support")
        service.getChatDelay = .milliseconds(150)
        let load = Task { await repo.loadChatIfNeeded(77) }
        let deadline = ContinuousClock.now + .seconds(1)
        while service.getChatRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(service.getChatRequests, [77])

        repo.resetLoadedState()
        await load.value

        XCTAssertNil(repo.chat(id: 77), "the answer belongs to the account that signed out")
    }

    func testMarkAsReadSkipsKnownReadChatOutsideTheList() async {
        repo.chats = [chat(1, order: 10)]
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0), positions: [], source: .newChat))

        await repo.markAsRead(chatId: 50, messageId: 9)

        XCTAssertTrue(service.readReceipts.isEmpty, "TDLib already counts no unread messages in chat 50")
    }

    func testMarkAsReadStillReachesTDLibForUnreadChatOutsideTheList() async {
        repo.handleChatPositionUpdate(.init(chat: chat(50, order: 0, unread: 3), positions: [], source: .newChat))

        await repo.markAsRead(chatId: 50, messageId: 9)

        XCTAssertEqual(service.readReceipts.map(\.chatId), [50])
        XCTAssertEqual(repo.chat(id: 50)?.unreadCount, 0)
    }

    func testRemoteNotificationUsesDirectoryTitleAndMute() async {
        let notifications = MockNotificationManager()
        let app = AppState(
            service: service, notificationManager: notifications, widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        defer {
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            app.chatRepository.invalidateChatListPrefetch()
            app.chatRepository.chatListCache.clear()
        }
        // Neither chat is in the list on screen, but TDLib announced both.
        app.chatRepository.handleChatPositionUpdate(.init(chat: chat(90, order: 0, title: "Alice"), positions: [], source: .newChat))
        var muted = chat(91, order: 0, title: "Noisy group")
        muted.isMuted = true
        app.chatRepository.handleChatPositionUpdate(.init(chat: muted, positions: [], source: .newChat))

        for chatId: Int64 in [90, 91] {
            await app.handleRemoteNotificationEvent(RemoteNotificationInfo(
                chatId: chatId, chatTitle: "From the push", senderName: "Bob", preview: "Hi",
                notificationKey: "\(chatId):1", playSound: true
            ))
        }

        XCTAssertEqual(notifications.postedNotifications.map(\.chatTitle), ["Alice"],
                       "the title is the directory's, and a muted chat stays quiet")
    }

    private func message(id: Int64, text: String) -> MessageInfo {
        MessageInfo(
            id: id, chatId: 50, senderName: "Bob", senderId: 2,
            content: .text(FormattedString(text: text)), date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: false
        )
    }

    private func chat(_ id: Int64, order: Int64, title: String? = nil, unread: Int = 0) -> ChatInfo {
        ChatInfo(
            id: id, title: title ?? "Chat \(id)", lastMessage: nil, unreadCount: unread,
            isGroup: false, isMuted: false, order: order
        )
    }
}
