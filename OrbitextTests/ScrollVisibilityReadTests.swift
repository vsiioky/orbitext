import XCTest
@testable import OrbitextWatch

/// Per-message read receipts on scroll visibility.
/// Covers the dedup + filter logic in `ScrollVisibilityRead` and the
/// repository-level `markMessageAsRead` path so we know exactly when
/// the watch will (and will not) fire `viewMessages` to the server.
@MainActor
final class ScrollVisibilityReadTests: XCTestCase {
    // MARK: - Fixtures

    private func makeIncoming(id: Int64, isRead: Bool = false, albumId: Int64 = 0) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: 1,
            senderName: "Alice",
            senderId: 2,
            content: .text(FormattedString(text: "m\(id)", entities: [])),
            date: Date(),
            isOutgoing: false,
            isRead: isRead,
            mediaAlbumId: albumId
        )
    }

    private func makeOutgoing(id: Int64, albumId: Int64 = 0) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: 1,
            senderName: "Me",
            senderId: 99,
            content: .text(FormattedString(text: "m\(id)", entities: [])),
            date: Date(),
            isOutgoing: true,
            isRead: true,
            mediaAlbumId: albumId
        )
    }

    // MARK: - shouldMark

    func testShouldMarkInsertsAndReturnsTrueOnFirstVisibility() {
        var sent: Set<Int64> = []
        let msg = makeIncoming(id: 100)

        XCTAssertTrue(ScrollVisibilityRead.shouldMark(message: msg, sent: &sent))
        XCTAssertTrue(sent.contains(100))
    }

    func testShouldMarkReturnsFalseOnRepeatVisibility() {
        var sent: Set<Int64> = []
        let msg = makeIncoming(id: 100)

        _ = ScrollVisibilityRead.shouldMark(message: msg, sent: &sent)

        // Micro-scroll flips visible -> not-visible -> visible again.
        XCTAssertFalse(ScrollVisibilityRead.shouldMark(message: msg, sent: &sent))
        XCTAssertFalse(ScrollVisibilityRead.shouldMark(message: msg, sent: &sent))
        XCTAssertEqual(sent.count, 1)
    }

    func testShouldMarkRejectsOutgoingMessages() {
        var sent: Set<Int64> = []
        let msg = makeOutgoing(id: 200)

        XCTAssertFalse(ScrollVisibilityRead.shouldMark(message: msg, sent: &sent))
        XCTAssertTrue(sent.isEmpty)
    }

    func testShouldMarkRejectsAlreadyReadMessages() {
        var sent: Set<Int64> = []
        let msg = makeIncoming(id: 300, isRead: true)

        XCTAssertFalse(ScrollVisibilityRead.shouldMark(message: msg, sent: &sent))
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Albums

    func testAlbumPropagatesToEveryIncomingUnreadMember() {
        var sent: Set<Int64> = []
        let album = MessageAlbumInfo(
            albumId: 555,
            messages: [
                makeIncoming(id: 1, albumId: 555),
                makeIncoming(id: 2, albumId: 555),
                makeIncoming(id: 3, albumId: 555)
            ]
        )

        let ids = ScrollVisibilityRead.messagesToMark(album: album, sent: &sent)

        XCTAssertEqual(ids, [1, 2, 3])
        XCTAssertEqual(sent, [1, 2, 3])
    }

    func testAlbumSkipsAlreadyReadAndOutgoingMembersIndependently() {
        var sent: Set<Int64> = []
        let album = MessageAlbumInfo(
            albumId: 777,
            messages: [
                makeIncoming(id: 10, isRead: true, albumId: 777), // already read
                makeOutgoing(id: 11, albumId: 777), // outgoing
                makeIncoming(id: 12, albumId: 777) // eligible
            ]
        )

        let ids = ScrollVisibilityRead.messagesToMark(album: album, sent: &sent)

        XCTAssertEqual(ids, [12])
        XCTAssertEqual(sent, [12])
    }

    func testAlbumSecondVisibilityReturnsEmpty() {
        var sent: Set<Int64> = []
        let album = MessageAlbumInfo(
            albumId: 888,
            messages: [
                makeIncoming(id: 20, albumId: 888),
                makeIncoming(id: 21, albumId: 888)
            ]
        )

        _ = ScrollVisibilityRead.messagesToMark(album: album, sent: &sent)
        let second = ScrollVisibilityRead.messagesToMark(album: album, sent: &sent)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(sent, [20, 21])
    }

    // MARK: - Coordinator

    func testCoordinatorDedupesSingleMessages() {
        var coordinator = ScrollVisibilityReadCoordinator()
        let msg = makeIncoming(id: 100)

        XCTAssertEqual(coordinator.messageIdToMark(msg), 100)
        XCTAssertNil(coordinator.messageIdToMark(msg))
    }

    func testCoordinatorDedupesAcrossMessageAndAlbum() {
        var coordinator = ScrollVisibilityReadCoordinator()
        let first = makeIncoming(id: 1, albumId: 555)
        let album = MessageAlbumInfo(
            albumId: 555,
            messages: [
                first,
                makeIncoming(id: 2, albumId: 555)
            ]
        )

        XCTAssertEqual(coordinator.messageIdToMark(first), 1)
        XCTAssertEqual(coordinator.messageIdsToMark(album), [2])
        XCTAssertTrue(coordinator.messageIdsToMark(album).isEmpty)
    }

    // MARK: - Repository wiring

    func testMarkMessageAsReadRoutesToServiceWithoutTouchingLocalBadge() async {
        let service = MockTelegramService()
        let widgetSync = MockWidgetSync()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000
        repo.chats = [
            ChatInfo(id: 42, title: "Bob", lastMessage: nil, unreadCount: 5, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markMessageAsRead(chatId: 42, messageId: 1000)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceipts.count, 1)
        XCTAssertEqual(service.readReceipts.first?.chatId, 42)
        XCTAssertEqual(service.readReceipts.first?.messageId, 1000)
        // Per-message path defers badge updates to updateChatReadInbox.
        XCTAssertEqual(repo.chats.first?.unreadCount, 5)
        XCTAssertTrue(widgetSync.updates.isEmpty)
    }

    func testMarkMessageAsReadFiresEvenWhenLocalUnreadIsZero() async {
        // The whole-chat markAsRead short-circuits at unreadCount == 0.
        // The per-message path must NOT - we still want the server to
        // see the explicit viewMessages call for the visible row.
        let service = MockTelegramService()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000
        repo.chats = [
            ChatInfo(id: 7, title: "C", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceipts.count, 1)
        XCTAssertEqual(service.readReceipts.first?.messageId, 9001)
    }

    func testMarkMessageAsReadDedupesSameMessageAtRepositoryLevel() async {
        let service = MockTelegramService()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 7, messageId: 9002)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceipts.map(\.messageId), [9001, 9002])
    }

    func testReadReceiptDedupeIsSharedWithWholeChatMarkAsRead() async {
        let service = MockTelegramService()
        let widgetSync = MockWidgetSync()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000
        repo.chats = [
            ChatInfo(id: 7, title: "C", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)

        XCTAssertEqual(service.readReceipts.map(\.messageId), [9001])
        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 0)
    }

    func testReadReceiptDedupeHandlesVisibilityThenWholeChatMarkAsRead() async {
        let service = MockTelegramService()
        let widgetSync = MockWidgetSync()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000
        repo.chats = [
            ChatInfo(id: 7, title: "C", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 1)
        ]

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceipts.map(\.messageId), [9001])
        XCTAssertEqual(repo.chats.first?.unreadCount, 0)
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 0)
    }

    func testMarkMessageAsReadBatchesVisibleMessagesPerChat() async {
        let service = MockTelegramService()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000

        await repo.markMessageAsRead(chatId: 7, messageId: 9003)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 7, messageId: 9002)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceiptBatches.count, 1)
        XCTAssertEqual(service.readReceiptBatches.first?.chatId, 7)
        XCTAssertEqual(service.readReceiptBatches.first?.messageIds, [9001, 9002, 9003])
    }

    func testMarkMessageAsReadBatchesByChat() async {
        let service = MockTelegramService()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 8, messageId: 8001)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceiptBatches.count, 2)
        XCTAssertEqual(
            service.readReceiptBatches.map { "\($0.chatId):\($0.messageIds)" }.sorted(),
            ["7:[9001]", "8:[8001]"]
        )
    }

    /// The repository kept every id it ever reported until sign-out: one per
    /// incoming message that scrolled into view, and an incoming message is
    /// never read as far as the app can tell. Leaving the chat ends the visit
    /// the ids belonged to; the next visit reports what it shows again.
    func testReleasingAChatForgetsWhichMessagesWereReported() async {
        let service = MockTelegramService()
        let repo = makeRepository(service)

        for id in [9001, 9002, 9003] as [Int64] {
            await repo.markMessageAsRead(chatId: 7, messageId: id)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(repo.readReceiptMessageIdsByChat[7]?.count, 3)

        repo.releaseReadReceipts(chatId: 7)

        XCTAssertNil(repo.readReceiptMessageIdsByChat[7], "Three ids stayed for the life of the process")
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(service.readReceiptBatches.map(\.messageIds), [[9001, 9002, 9003], [9001]],
                       "The next visit reports what scrolls into view again")
    }

    func testReleasingAChatKeepsTheReceiptsStillWaitingForTheFlush() async {
        let service = MockTelegramService()
        let repo = makeRepository(service)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)

        repo.releaseReadReceipts(chatId: 7)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceiptBatches.map(\.messageIds), [[9001]],
                       "Leaving the chat neither loses the report nor sends it twice")
    }

    func testReleasingOneChatLeavesTheOtherChatsReceipts() async {
        let service = MockTelegramService()
        let repo = makeRepository(service)
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        await repo.markMessageAsRead(chatId: 8, messageId: 8001)

        repo.releaseReadReceipts(chatId: 7)

        XCTAssertNil(repo.readReceiptMessageIdsByChat[7])
        XCTAssertEqual(repo.readReceiptMessageIdsByChat[8], [8001])
    }

    private func makeRepository(_ service: MockTelegramService) -> ChatRepository {
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000
        return repo
    }

    func testMarkMessageAsReadDebouncesContinuousVisibility() async {
        let service = MockTelegramService()
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 150_000_000

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await repo.markMessageAsRead(chatId: 7, messageId: 9002)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(service.readReceiptBatches.isEmpty)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(service.readReceiptBatches.count, 1)
        XCTAssertEqual(service.readReceiptBatches.first?.messageIds, [9001, 9002])
    }

    func testMarkMessageAsReadRetriesAfterServiceError() async {
        let service = MockTelegramService()
        service.markAsReadError = TestError.failed("offline")
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.readReceiptFlushDelayNanos = 50_000_000

        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)
        service.markAsReadError = nil
        await repo.markMessageAsRead(chatId: 7, messageId: 9001)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(service.readReceipts.map(\.messageId), [9001])
    }

    func testMarkMessageAsReadSwallowsServiceErrors() async {
        let service = MockTelegramService()
        service.markAsReadError = TestError.failed("offline")
        let repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        // Must not throw - scroll observers fire continuously and we
        // do not want a transient network error to crash the view.
        await repo.markMessageAsRead(chatId: 1, messageId: 1)
    }

    // MARK: - WatchChatScrollState

    func testWatchChatScrollStateResetRestoresInitialValues() {
        var state = WatchChatScrollState(
            scrollTarget: "1:10",
            atBottom: false,
            unreadNewCount: 3,
            anchorBeforeLoad: "1:1",
            initialScrollDone: true,
            paginationEnabled: true
        )

        state.resetForChatOpen()

        XCTAssertNil(state.scrollTarget)
        XCTAssertTrue(state.atBottom)
        XCTAssertEqual(state.unreadNewCount, 0)
        XCTAssertNil(state.anchorBeforeLoad)
        XCTAssertFalse(state.initialScrollDone)
        XCTAssertFalse(state.paginationEnabled)
    }

    func testWatchChatScrollStateScrollsAndMarksReadForIncomingAtBottom() {
        var state = WatchChatScrollState()
        state.revealInitialMessages()
        state.atBottom = true
        let message = makeIncoming(id: 101)

        let action = state.handleNewMessage(oldId: 100, message: message)

        XCTAssertEqual(action, .scrollAndMarkRead(messageId: 101))
        XCTAssertEqual(state.scrollTarget, "1:101")
        XCTAssertEqual(state.unreadNewCount, 0)
    }

    func testWatchChatScrollStateIncrementsUnreadForIncomingAwayFromBottom() {
        var state = WatchChatScrollState()
        state.revealInitialMessages()
        state.atBottom = false
        state.updateBottomDistance(240, viewportHeight: 240)
        let message = makeIncoming(id: 101)

        let action = state.handleNewMessage(oldId: 100, message: message)

        XCTAssertEqual(action, .incrementUnread)
        XCTAssertNil(state.scrollTarget)
        XCTAssertEqual(state.unreadNewCount, 1)
        XCTAssertTrue(state.canShowUnreadButton)
    }

    func testWatchChatScrollStateAlwaysScrollsOutgoingMessages() {
        var state = WatchChatScrollState()
        state.revealInitialMessages()
        state.atBottom = false
        let message = makeOutgoing(id: 101)

        let action = state.handleNewMessage(oldId: 100, message: message)

        XCTAssertEqual(action, .scrollAndMarkRead(messageId: 101))
        XCTAssertEqual(state.scrollTarget, "1:101")
        XCTAssertEqual(state.unreadNewCount, 0)
    }

    func testWatchChatScrollStateIgnoresOlderOrInitialUnreadyMessageChanges() {
        var state = WatchChatScrollState()

        XCTAssertEqual(state.handleNewMessage(oldId: 100, message: makeIncoming(id: 101)), .ignore)

        state.revealInitialMessages()
        state.atBottom = false
        XCTAssertEqual(state.handleNewMessage(oldId: 100, message: makeIncoming(id: 99)), .ignore)
        XCTAssertNil(state.scrollTarget)
        XCTAssertEqual(state.unreadNewCount, 0)
    }

    func testWatchChatScrollStateConsumesOlderLoadAnchorOnce() {
        var state = WatchChatScrollState()
        state.prepareOlderLoad(anchorViewID: "1:10")

        XCTAssertNil(state.consumeOlderLoadAnchor())

        state.revealInitialMessages()
        XCTAssertEqual(state.consumeOlderLoadAnchor(), "1:10")
        XCTAssertNil(state.consumeOlderLoadAnchor())
    }
}
