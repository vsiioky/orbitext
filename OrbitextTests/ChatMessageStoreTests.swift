import XCTest
@testable import OrbitextWatch

@MainActor
final class ChatMessageStoreTests: XCTestCase {
    private var service: MockTelegramService!
    private var store: ChatMessageStore!
    private var chatRepository: ChatRepository!

    override func setUp() async throws {
        service = MockTelegramService()
        let messageManager = MessageManager(service: service, messageQueue: MessageQueue())
        chatRepository = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        store = ChatMessageStore(messageManager: messageManager, chatRepository: chatRepository)
    }

    func testLoadInitialMessagesStoresChronologicalMessages() async {
        let older = MessageInfo(id: 1, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Older"), date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: false)
        let newer = MessageInfo(id: 2, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Newer"), date: Date(timeIntervalSince1970: 2), isOutgoing: false, isRead: false)
        service.messagesByChatId[5] = [older, newer]

        let result = await store.loadInitialMessages(chatId: 5)

        XCTAssertEqual(result.messages.map(\.id), [1, 2])
        XCTAssertEqual(store.messages(for: 5).map(\.id), [1, 2])
        XCTAssertEqual(service.readReceipts.last?.messageId, 2)
    }

    func testReadStatusUsesDirectoryForUnlistedChat() async {
        announceUnlistedChat(5, lastReadOutboxMessageId: 50)
        let read = outgoing(id: 40)
        let unread = outgoing(id: 60)
        service.messagesByChatId[5] = [read, unread]

        let result = await store.loadInitialMessages(chatId: 5)

        XCTAssertEqual(result.messages.map(\.isRead), [true, false])
    }

    func testOlderMessagesUseDirectoryReadStatusForUnlistedChat() async {
        announceUnlistedChat(5, lastReadOutboxMessageId: 50)
        service.messagesByChatId[5] = [outgoing(id: 40), outgoing(id: 60), outgoing(id: 70)]
        store.reset(chatId: 5)
        store.handleIncomingMessage(outgoing(id: 70))

        await store.loadOlderMessages(chatId: 5)

        XCTAssertEqual(store.messages(for: 5).map(\.id), [40, 60, 70])
        XCTAssertEqual(store.messages(for: 5).map(\.isRead), [true, false, false])
    }

    func testSendCompletionUsesDirectoryReadStatusForUnlistedChat() {
        announceUnlistedChat(5, lastReadOutboxMessageId: 50)
        var pending = outgoing(id: 1_000)
        pending.isSending = true
        store.reset(chatId: 5)
        store.handleIncomingMessage(pending)

        store.handleMessageSendCompleted(oldMessageId: 1_000, message: outgoing(id: 40))

        XCTAssertEqual(store.messages(for: 5).map(\.id), [40])
        XCTAssertEqual(store.messages(for: 5).map(\.isRead), [true])
    }

    func testLoadInitialMessagesKeepsShortHistoryWhenWarmupDoesNotImproveIt() async {
        let onlyMessage = MessageInfo(id: 10, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Only"), date: Date(timeIntervalSince1970: 10), isOutgoing: false, isRead: false)
        service.messagesByChatId[5] = [onlyMessage]

        let result = await store.loadInitialMessages(chatId: 5)

        XCTAssertEqual(result.messages.map(\.id), [10])
        XCTAssertEqual(service.getMessagesRequests.map(\.fromMessageId), [0, 0, 10])
    }

    func testLoadInitialMessagesWarmsUpShortLatestOnlyHistory() async {
        let older = MessageInfo(id: 9, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Older"), date: Date(timeIntervalSince1970: 9), isOutgoing: false, isRead: false)
        let newest = MessageInfo(id: 10, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Newest"), date: Date(timeIntervalSince1970: 10), isOutgoing: false, isRead: false)
        service.getMessagesScriptedResponses = [
            [newest],
            [newest, older]
        ]

        let result = await store.loadInitialMessages(chatId: 5)

        XCTAssertEqual(result.messages.map(\.id), [9, 10])
        XCTAssertEqual(store.messages(for: 5).map(\.id), [9, 10])
        // Initial load now also pulls one older page past the warm-up
        // result to fill the first screen (e26f3cc).
        XCTAssertEqual(service.getMessagesRequests.map(\.fromMessageId), [0, 0, 9])
    }

    func testLoadInitialMessagesFetchesOlderWhenWarmupStaysShort() async {
        let older = MessageInfo(id: 8, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Older"), date: Date(timeIntervalSince1970: 8), isOutgoing: false, isRead: false)
        let newest = MessageInfo(id: 10, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Newest"), date: Date(timeIntervalSince1970: 10), isOutgoing: false, isRead: false)
        service.getMessagesScriptedResponses = [
            [newest],
            [newest],
            [older]
        ]

        let result = await store.loadInitialMessages(chatId: 5)

        XCTAssertEqual(result.messages.map(\.id), [8, 10])
        XCTAssertEqual(store.messages(for: 5).map(\.id), [8, 10])
        XCTAssertEqual(service.getMessagesRequests.map(\.fromMessageId), [0, 0, 10])
    }

    func testHandleIncomingMessageResolvesReplyPreviewFromStore() async {
        let original = MessageInfo(id: 10, chatId: 1, senderName: "Bob", senderId: 3, content: .text("Original"), date: Date(), isOutgoing: false, isRead: true)
        service.messagesByChatId[1] = [original]
        _ = await store.loadInitialMessages(chatId: 1)

        let reply = MessageInfo(id: 11, chatId: 1, senderName: "Alice", senderId: 2, content: .text("Reply"), date: Date(), isOutgoing: false, isRead: false, replyToMessageId: 10)
        store.handleIncomingMessage(reply)

        let appended = store.messages(for: 1).last
        XCTAssertEqual(appended?.replyToSenderName, "Bob")
        XCTAssertEqual(appended?.replyToPreview, "Original")
    }

    func testLoadOlderMessagesStopsAfterHistoryIsExhausted() async {
        let onlyMessage = MessageInfo(id: 10, chatId: 5, senderName: "Alice", senderId: 2, content: .text("Only"), date: Date(timeIntervalSince1970: 10), isOutgoing: false, isRead: false)
        service.messagesByChatId[5] = [onlyMessage]
        _ = await store.loadInitialMessages(chatId: 5)

        await store.loadOlderMessages(chatId: 5)
        await store.loadOlderMessages(chatId: 5)

        // Initial load issues warm-up retry + older-page fill (e26f3cc),
        // then the first explicit loadOlder confirms exhaustion; the
        // second is a no-op.
        XCTAssertEqual(service.getMessagesRequests.map(\.fromMessageId), [0, 0, 10, 10])
        XCTAssertFalse(store.canLoadOlder(chatId: 5))
    }

    /// clearInactiveChats (called from handleEnteredBackground)
    /// must preserve the chat the user is currently viewing. Otherwise a
    /// quick background/foreground cycle blanks the open chat because
    /// ChatView.task is keyed on chatId and does not refire on
    /// scenePhase .active.
    func testClearInactiveChatsPreservesActiveChat() {
        let m1 = MessageInfo(id: 1, chatId: 1, senderName: "Alice", senderId: 2, content: .text("a"), date: Date(), isOutgoing: false, isRead: false)
        let m2 = MessageInfo(id: 2, chatId: 2, senderName: "Bob", senderId: 3, content: .text("b"), date: Date(), isOutgoing: false, isRead: false)
        store.reset(chatId: 1)
        store.reset(chatId: 2)
        store.handleIncomingMessage(m1)
        store.handleIncomingMessage(m2)

        store.setActiveChat(2)
        store.clearInactiveChats()

        // Chat 1 was inactive -> cleared. Chat 2 was active -> preserved.
        XCTAssertTrue(store.messages(for: 1).isEmpty)
        XCTAssertEqual(store.messages(for: 2).map(\.id), [2])
        XCTAssertEqual(store.activeChatId, 2)
    }

    func testClearInactiveChatsWipesAllWhenNoActiveChat() {
        let m1 = MessageInfo(id: 1, chatId: 1, senderName: "Alice", senderId: 2, content: .text("a"), date: Date(), isOutgoing: false, isRead: false)
        let m2 = MessageInfo(id: 2, chatId: 2, senderName: "Bob", senderId: 3, content: .text("b"), date: Date(), isOutgoing: false, isRead: false)
        store.reset(chatId: 1)
        store.reset(chatId: 2)
        store.handleIncomingMessage(m1)
        store.handleIncomingMessage(m2)

        store.setActiveChat(nil)
        store.clearInactiveChats()

        XCTAssertTrue(store.messages(for: 1).isEmpty)
        XCTAssertTrue(store.messages(for: 2).isEmpty)
    }

    func testOptimisticToggleReactionAddsAndRemovesReaction() {
        let message = MessageInfo(id: 1, chatId: 1, senderName: "Alice", senderId: 2, content: .text("Hi"), date: Date(), isOutgoing: false, isRead: false)
        store.reset(chatId: 1)
        store.handleIncomingMessage(message)

        let shouldRemoveAfterAdd = store.optimisticToggleReaction(chatId: 1, messageId: 1, reactionValue: "👍")
        let shouldRemoveAfterToggle = store.optimisticToggleReaction(chatId: 1, messageId: 1, reactionValue: "👍")

        XCTAssertFalse(shouldRemoveAfterAdd)
        XCTAssertTrue(shouldRemoveAfterToggle)
        XCTAssertTrue(store.messages(for: 1).first?.reactions.isEmpty ?? false)
    }

    // MARK: - Chats nobody has open

    /// Every chat TDLib talks about sends events here. A chat nobody opened
    /// has no history to extend: a one-message entry would be dropped on
    /// open anyway, and writing it wakes every screen that reads any chat.
    func testIncomingMessageOfAChatNobodyOpenedIsNotKept() {
        store.handleIncomingMessage(outgoing(id: 1, chatId: 9))

        XCTAssertTrue(store.messages(for: 9).isEmpty)
    }

    func testLiveEventsOfAChatNobodyOpenedLeaveTheOpenChatsReadersAlone() {
        store.reset(chatId: 5)
        store.handleIncomingMessage(outgoing(id: 1, chatId: 5))

        XCTAssertFalse(readersAreNotified(of: { store.messages(for: 5) }) {
            store.handleIncomingMessage(outgoing(id: 1, chatId: 9))
        }, "A message of another chat")
        XCTAssertFalse(readersAreNotified(of: { store.messages(for: 5) }) {
            store.handleDeleteMessages(chatId: 9, messageIds: [1])
        }, "A deletion in another chat")
        XCTAssertFalse(readersAreNotified(of: { store.messages(for: 5) }) {
            store.handleMessageSendCompleted(oldMessageId: 1, message: outgoing(id: 2, chatId: 9))
        }, "A send completion in another chat")
        XCTAssertFalse(readersAreNotified(of: { store.messages(for: 5) }) {
            store.updateReadStatus(chatId: 9, lastReadOutboxMessageId: 4)
        }, "A read receipt in another chat")
        XCTAssertFalse(readersAreNotified(of: { store.messages(for: 5) }) {
            store.updateMessage(chatId: 9, messageId: 1) { $0.isRead = true }
        }, "An edit in another chat")
        XCTAssertTrue(readersAreNotified(of: { store.messages(for: 5) }) {
            store.handleIncomingMessage(outgoing(id: 2, chatId: 5))
        }, "The open chat still hears its own messages")
    }

    /// Message rows read the properties cache for their long-press menu, so a
    /// write to it redraws every row of the open chat.
    func testClearingPropertiesNobodyCachedDoesNotWakeTheRows() {
        XCTAssertFalse(readersAreNotified(of: { store.cachedProperties(chatId: 5, messageId: 1) }) {
            store.handleDeleteMessages(chatId: 9, messageIds: [1, 2, 3])
        }, "Nothing was cached for those messages")
        XCTAssertFalse(readersAreNotified(of: { store.cachedProperties(chatId: 5, messageId: 1) }) {
            store.handleMessageSendCompleted(oldMessageId: -1, message: outgoing(id: 2, chatId: 9))
        })
    }

    func testReleasedChatTakesNoLiveMessagesUntilItIsOpenedAgain() {
        store.reset(chatId: 5)
        store.handleIncomingMessage(outgoing(id: 1, chatId: 5))
        XCTAssertEqual(store.messages(for: 5).map(\.id), [1])

        store.release(chatId: 5)
        store.handleIncomingMessage(outgoing(id: 2, chatId: 5))

        XCTAssertTrue(store.messages(for: 5).isEmpty, "Leaving the chat frees its history for good")

        store.reset(chatId: 5)
        store.handleIncomingMessage(outgoing(id: 3, chatId: 5))
        XCTAssertEqual(store.messages(for: 5).map(\.id), [3])
    }

    func testHasHistoryIsTrueForAnOpenChatEvenWhenItHoldsNoMessage() {
        XCTAssertFalse(store.hasHistory(for: 5))

        store.reset(chatId: 5)

        XCTAssertTrue(store.hasHistory(for: 5), "An empty chat is loaded: there is nothing to fetch again")
    }

    func testHasHistoryIsFalseOnceTheChatIsReleasedOrTheBackgroundFreedIt() {
        store.reset(chatId: 5)
        store.reset(chatId: 6)
        store.release(chatId: 5)
        XCTAssertFalse(store.hasHistory(for: 5))

        store.setActiveChat(9)
        store.clearInactiveChats()

        XCTAssertFalse(store.hasHistory(for: 6), "The background frees every chat but the open one")
    }

    /// Tells whether `read` is told to look again because of `action`.
    private func readersAreNotified(of read: () -> some Any, after action: () -> Void) -> Bool {
        let notified = ObservationFlag()
        withObservationTracking {
            _ = read()
        } onChange: {
            notified.raise()
        }
        action()
        return notified.isRaised
    }

    /// TDLib announced the chat, but it is not in the list on screen.
    private func announceUnlistedChat(_ chatId: Int64, lastReadOutboxMessageId: Int64) {
        var announced = ChatInfo(
            id: chatId, title: "Far down", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0
        )
        announced.lastReadOutboxMessageId = lastReadOutboxMessageId
        chatRepository.handleChatPositionUpdate(.init(chat: announced, positions: [], source: .newChat))
    }

    private func outgoing(id: Int64, chatId: Int64 = 5) -> MessageInfo {
        MessageInfo(
            id: id, chatId: chatId, senderName: "Me", senderId: 1, content: .text(FormattedString(text: "Message \(id)")),
            date: Date(timeIntervalSince1970: TimeInterval(id)), isOutgoing: true, isRead: false
        )
    }
}
