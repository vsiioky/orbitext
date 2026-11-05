import XCTest
@testable import OrbitextWatch

final class ChatScrollDeletionTests: XCTestCase {
    func testDeletingLatestMessageStillRequestsAlignmentWhenTargetAlreadyNamesSurvivor() {
        var state = readyState()
        state.scrollTarget = "1:100"

        // Open at 100, receive 200 while reading older history, then return
        // to the bottom manually. Deleting 200 must work even though the
        // surviving 100 is already the stored target and cannot fire onChange.
        let action = state.handleNewMessage(oldId: 200, message: message(id: 100))

        XCTAssertEqual(action, .realignBottom(lastMessageId: 100),
                       "Deletion needs a fresh scroll intent independent of target equality")
        XCTAssertEqual(state.scrollTarget, "1:100")
    }

    func testDeletingLatestMessageAtRestRepinsRemainingMessageWithoutReadReceipt() {
        let remaining = message(id: 100)
        var state = WatchChatScrollState(
            scrollTarget: "1:200",
            atBottom: true,
            unreadNewCount: 0,
            initialScrollDone: true,
            paginationEnabled: true
        )

        // ChatView observes the last ID change from the removed reply (200)
        // to its surviving original (100). Ignoring this shrink leaves the
        // viewport anchored past the surviving row on watchOS.
        let action = state.handleNewMessage(oldId: 200, message: remaining)

        XCTAssertEqual(action, .realignBottom(lastMessageId: remaining.id),
                       "Deleting the latest row must request alignment without a read receipt or unread notification")
        XCTAssertEqual(state.unreadNewCount, 0)
        XCTAssertTrue(state.canShowComposer)
    }

    func testDeletingOnlyMessageRepinsEmptyStateAndClearsPaginationAnchor() {
        var state = readyState()
        state.prepareOlderLoad(anchorViewID: "1:100")

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: nil), .realignBottom(lastMessageId: nil))

        XCTAssertNil(state.consumeOlderLoadAnchor())
        XCTAssertEqual(state.unreadNewCount, 0)
        XCTAssertTrue(state.canShowComposer)

        let completed = state
        XCTAssertEqual(state.handleNewMessage(oldId: nil, message: nil), .ignore)
        XCTAssertEqual(state, completed, "An already-empty history must not create another scroll request")
    }

    func testDeletingLatestMessageWhileReadingOlderHistoryPreservesPositionAndUnreadCount() {
        var state = readyState()
        state.atBottom = false
        state.unreadNewCount = 3
        state.prepareOlderLoad(anchorViewID: "1:10")
        let before = state

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .ignore)

        XCTAssertEqual(state, before, "Deleting the latest row must not pull an older-history reader to the bottom")
    }

    func testDeletingLatestMessageDuringGesturePreservesPosition() {
        var state = readyState()
        state.isUserScrolling = true
        let before = state

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .ignore)

        XCTAssertEqual(state, before)
    }

    func testDeletingDuringInitialLoadDoesNotRevealOrScrollHistory() {
        var state = WatchChatScrollState()
        let before = state

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .ignore)
        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: nil), .ignore)

        XCTAssertEqual(state, before)
    }

    func testConsecutiveLastMessageDeletionsEachRequestAlignment() {
        var state = readyState()
        state.prepareOlderLoad(anchorViewID: "1:50")

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .realignBottom(lastMessageId: 100))
        XCTAssertNil(state.consumeOlderLoadAnchor(), "A pending prepend must not undo bottom alignment after deletion")
        XCTAssertEqual(state.handleNewMessage(oldId: 100, message: message(id: 50)), .realignBottom(lastMessageId: 50))
        XCTAssertEqual(state.handleNewMessage(oldId: 50, message: nil), .realignBottom(lastMessageId: nil))
        XCTAssertEqual(state.unreadNewCount, 0)
    }

    func testIncomingSurvivorDoesNotCreateReadReceiptOrUnreadNotification() {
        var state = readyState()
        var remaining = message(id: 100)
        remaining.isOutgoing = false

        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: remaining), .realignBottom(lastMessageId: 100))

        XCTAssertEqual(state.unreadNewCount, 0)
    }

    func testDelayedRealignmentStopsWhenUserStartsScrolling() {
        var state = readyState()
        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .realignBottom(lastMessageId: 100))
        XCTAssertTrue(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: 100))

        state.isUserScrolling = true
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: 100))

        state.isUserScrolling = false
        state.atBottom = false
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: 100))
    }

    func testDelayedRealignmentStopsAfterHistoryChangesOrChatResets() {
        var state = readyState()
        XCTAssertEqual(state.handleNewMessage(oldId: 200, message: message(id: 100)), .realignBottom(lastMessageId: 100))
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: 300))
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: nil))
        XCTAssertTrue(state.canApplyBottomRealignment(lastMessageId: nil, currentLastMessageId: nil))

        state.resetForChatOpen()
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: 100, currentLastMessageId: 100))
        XCTAssertFalse(state.canApplyBottomRealignment(lastMessageId: nil, currentLastMessageId: nil))
    }

    func testOlderLoadAnchorNamesTheAlbumRowWhenHistoryStartsWithAnAlbum() {
        var state = readyState()
        var first = message(id: 10)
        first.mediaAlbumId = 7
        var second = message(id: 11)
        second.mediaAlbumId = 7

        let page = [first, second, message(id: 12)]
        state.prepareOlderLoad(topOf: page)

        // The list renders an album as one row with this id; a message id
        // inside it matches no row and the scroll position jumps.
        XCTAssertEqual(state.consumeOlderLoadAnchor(in: [message(id: 5)] + page), "album:7")
    }

    func testOlderLoadAnchorFollowsAnAlbumTailThatMergesAfterTheLoad() {
        var state = readyState()
        func album7(_ id: Int64) -> MessageInfo {
            var m = message(id: id)
            m.mediaAlbumId = 7
            return m
        }
        // The page boundary cut the album: only its last photo was loaded.
        let page = [album7(11), message(id: 12)]
        state.prepareOlderLoad(topOf: page)

        let afterLoad = [album7(9), album7(10)] + page

        XCTAssertEqual(state.consumeOlderLoadAnchor(in: afterLoad), "album:7",
                       "Row 1:11 no longer exists once its album siblings arrive")
    }

    func testDeepLinkLoadsOlderOnlyAfterItsJump() {
        XCTAssertGreaterThan(WatchChatScrollState.paginationDelay(isDeepLink: true),
                             WatchChatScrollState.deepLinkJumpDelay,
                             "Load-older would fire before the jump to the searched message")
        XCTAssertEqual(WatchChatScrollState.paginationDelay(isDeepLink: false), 0.5)
    }

    func testOlderLoadAnchorNamesTheMessageRowOtherwise() {
        var state = readyState()

        let page = [message(id: 10), message(id: 11)]
        state.prepareOlderLoad(topOf: page)

        XCTAssertEqual(state.consumeOlderLoadAnchor(in: [message(id: 9)] + page), "1:10")
    }

    private func readyState() -> WatchChatScrollState {
        WatchChatScrollState(
            scrollTarget: "1:200",
            atBottom: true,
            initialScrollDone: true,
            paginationEnabled: true
        )
    }

    private func message(id: Int64) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: 1,
            senderName: "Me",
            senderId: 1,
            content: .text(FormattedString(text: "Our test message", entities: [])),
            date: Date(timeIntervalSince1970: TimeInterval(id)),
            isOutgoing: true,
            isRead: false
        )
    }
}

/// Rows compare by their data so `.equatable()` skips re-rendering a row
/// whose message did not change when any other part of the chat updates.
final class ChatRowEquatableTests: XCTestCase {
    @MainActor
    func testMessageRowsWithTheSameMessageAreEqualDespiteNewClosures() {
        let message = MessageInfo(id: 1, chatId: 1, senderName: "A", senderId: 2, content: .text("Hi"),
                                  date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: true)
        var edited = message
        edited.content = .text("Hi, edited")

        XCTAssertEqual(MessageRow(message: message, isGroup: false, onReply: {}),
                       MessageRow(message: message, isGroup: false, onReply: {}))
        XCTAssertNotEqual(MessageRow(message: message, isGroup: false),
                          MessageRow(message: edited, isGroup: false))
        XCTAssertNotEqual(MessageRow(message: message, isGroup: false),
                          MessageRow(message: message, isGroup: true))
        // Everything a row draws outside the text must also break equality.
        var reacted = message
        reacted.reactions = [ReactionInfo(emoji: "👍", count: 1, isSelected: true)]
        var read = message
        read.isRead.toggle()
        var sending = message
        sending.isSending = true
        for changed in [reacted, read, sending] {
            XCTAssertNotEqual(MessageRow(message: message, isGroup: false),
                              MessageRow(message: changed, isGroup: false))
        }
    }

    @MainActor
    func testAlbumRowsCompareByAlbumAndWidth() {
        var first = MessageInfo(id: 1, chatId: 1, senderName: "A", senderId: 2, content: .text("1"),
                                date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: true)
        first.mediaAlbumId = 7
        var second = MessageInfo(id: 2, chatId: 1, senderName: "A", senderId: 2, content: .text("2"),
                                 date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: true)
        second.mediaAlbumId = 7
        let album = MessageAlbumInfo(albumId: 7, messages: [first, second])

        XCTAssertEqual(AlbumView(album: album, isGroup: false, availableWidth: 180, onReply: {}),
                       AlbumView(album: album, isGroup: false, availableWidth: 180, onReply: {}))
        XCTAssertNotEqual(AlbumView(album: album, isGroup: false, availableWidth: 180),
                          AlbumView(album: album, isGroup: false, availableWidth: 200))
        var reactedSecond = second
        reactedSecond.reactions = [ReactionInfo(emoji: "👍", count: 1, isSelected: true)]
        XCTAssertNotEqual(AlbumView(album: album, isGroup: false, availableWidth: 180),
                          AlbumView(album: MessageAlbumInfo(albumId: 7, messages: [first, reactedSecond]),
                                    isGroup: false, availableWidth: 180))
    }
}
