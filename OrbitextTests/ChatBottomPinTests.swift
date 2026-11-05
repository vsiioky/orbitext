import XCTest
@testable import OrbitextWatch

/// A bot rewriting the last message (menu navigation after a button press)
/// makes the row taller and pushes the bottom sentinel out of view. A reader
/// resting at the bottom must stay pinned there with the composer visible.
final class ChatBottomPinTests: XCTestCase {
    // MARK: - Fixtures

    private func message(
        id: Int64,
        text: String = "Menu",
        replyMarkup: ReplyMarkup? = nil,
        isRead: Bool = false,
        reactions: [ReactionInfo] = []
    ) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: 1,
            senderName: "Bot",
            senderId: 99,
            content: .text(FormattedString(text: text)),
            date: Date(timeIntervalSince1970: 0),
            isOutgoing: false,
            isRead: isRead,
            reactions: reactions,
            replyMarkup: replyMarkup
        )
    }

    private func keyboard(_ labels: String...) -> ReplyMarkup {
        .inlineKeyboard([labels.map { InlineKeyboardButton(text: $0, action: .callback(data: "AA==")) }])
    }

    private func restingAtBottom() -> WatchChatScrollState {
        var state = WatchChatScrollState()
        state.revealInitialMessages()
        return state
    }

    // MARK: - Layout change detection

    func testTextEditOfTheSameLastMessageIsALayoutChange() {
        XCTAssertTrue(WatchChatScrollState.lastMessageLayoutChanged(
            from: message(id: 5, text: "Main"),
            to: message(id: 5, text: "Main -> Settings")
        ))
    }

    func testKeyboardSwapIsALayoutChange() {
        XCTAssertTrue(WatchChatScrollState.lastMessageLayoutChanged(
            from: message(id: 5, replyMarkup: keyboard("Settings")),
            to: message(id: 5, replyMarkup: keyboard("Voice", "Limits", "Back"))
        ))
    }

    func testReactionChangeIsALayoutChange() {
        let reaction = ReactionInfo(emoji: "x", count: 1, isSelected: false)
        XCTAssertTrue(WatchChatScrollState.lastMessageLayoutChanged(
            from: message(id: 5),
            to: message(id: 5, reactions: [reaction])
        ))
    }

    func testReadStateChangeIsNotALayoutChange() {
        XCTAssertFalse(WatchChatScrollState.lastMessageLayoutChanged(
            from: message(id: 5, isRead: false),
            to: message(id: 5, isRead: true)
        ))
    }

    func testANewLastMessageIsNotAnInPlaceEdit() {
        XCTAssertFalse(WatchChatScrollState.lastMessageLayoutChanged(
            from: message(id: 5),
            to: message(id: 6, text: "Other")
        ))
    }

    func testMissingMessagesAreNotAnInPlaceEdit() {
        XCTAssertFalse(WatchChatScrollState.lastMessageLayoutChanged(from: nil, to: message(id: 5)))
        XCTAssertFalse(WatchChatScrollState.lastMessageLayoutChanged(from: message(id: 5), to: nil))
    }

    // MARK: - Pinning

    func testPinKeepsComposerVisibleWhileTheTallerRowPushesTheSentinelAway() {
        var state = restingAtBottom()

        XCTAssertTrue(state.beginBottomPin())
        // The visibility callback reports the sentinel left the viewport.
        state.atBottom = false

        XCTAssertTrue(state.canShowComposer)
        XCTAssertFalse(state.canShowUnreadButton)
    }

    func testPinAppliesEvenAfterAtBottomFlippedFalse() {
        var state = restingAtBottom()
        XCTAssertTrue(state.beginBottomPin())
        state.atBottom = false

        XCTAssertTrue(state.canApplyBottomPin(lastMessageId: 5, currentLastMessageId: 5))
    }

    func testPinIsNotAppliedWhenANewerMessageBecameLast() {
        var state = restingAtBottom()
        XCTAssertTrue(state.beginBottomPin())

        XCTAssertFalse(state.canApplyBottomPin(lastMessageId: 5, currentLastMessageId: 6))
    }

    func testReaderAwayFromBottomIsNotYankedDown() {
        var state = restingAtBottom()
        state.atBottom = false

        XCTAssertFalse(state.beginBottomPin())
        XCTAssertFalse(state.isPinningBottom)
        XCTAssertFalse(state.canShowComposer)
    }

    func testActiveScrollGestureIsNotOverridden() {
        var state = restingAtBottom()
        state.isUserScrolling = true

        XCTAssertFalse(state.beginBottomPin())
    }

    func testNoPinBeforeTheInitialScroll() {
        var state = WatchChatScrollState()

        XCTAssertFalse(state.beginBottomPin())
    }

    func testScrollGestureDuringAPinCancelsIt() {
        var state = restingAtBottom()
        XCTAssertTrue(state.beginBottomPin())
        state.atBottom = false

        state.isUserScrolling = true
        state.isUserScrolling = false

        XCTAssertFalse(state.isPinningBottom)
        XCTAssertFalse(state.canApplyBottomPin(lastMessageId: 5, currentLastMessageId: 5))
        XCTAssertFalse(state.canShowComposer)
    }

    func testFinishingThePinFallsBackToTheSentinel() {
        var state = restingAtBottom()
        XCTAssertTrue(state.beginBottomPin())
        state.atBottom = false

        state.finishBottomPin()

        XCTAssertFalse(state.isPinningBottom)
        XCTAssertFalse(state.canShowComposer)
        state.atBottom = true
        XCTAssertTrue(state.canShowComposer)
    }

    func testChatResetClearsAPendingPin() {
        var state = restingAtBottom()
        XCTAssertTrue(state.beginBottomPin())

        state.resetForChatOpen()

        XCTAssertFalse(state.isPinningBottom)
    }
}
