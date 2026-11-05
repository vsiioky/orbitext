import XCTest
@testable import OrbitextWatch

final class ChatComposerTests: XCTestCase {
    func testComposerAppearsOnlyAtRestAtLatestMessages() {
        var state = WatchChatScrollState()
        XCTAssertFalse(state.canShowComposer)
        state.revealInitialMessages()
        XCTAssertTrue(state.canShowComposer)
        state.isUserScrolling = true
        XCTAssertFalse(state.canShowComposer)
        state.atBottom = false
        state.isUserScrolling = false
        XCTAssertFalse(state.canShowComposer)
        state.updateBottomDistance(240, viewportHeight: 240)
        XCTAssertTrue(state.canShowUnreadButton, "History must offer a way back even without unread messages")
        state.atBottom = true
        XCTAssertTrue(state.canShowComposer)
        XCTAssertFalse(state.canShowUnreadButton)
    }

    func testEmptyChatFinishesLoadingAndAllowsFirstMessage() {
        var state = WatchChatScrollState()
        state.completeInitialLoad(target: nil)
        XCTAssertTrue(state.initialScrollDone)
        XCTAssertTrue(state.canShowComposer)
    }

    func testLatestButtonIgnoresSmallScrollsAndUsesHysteresis() {
        var state = WatchChatScrollState()
        state.revealInitialMessages()
        state.atBottom = false
        for distance: CGFloat in [1, 54, 120, 239] {
            state.updateBottomDistance(distance, viewportHeight: 240)
            XCTAssertFalse(state.canShowUnreadButton)
        }
        state.updateBottomDistance(240, viewportHeight: 240)
        XCTAssertTrue(state.canShowUnreadButton)
        state.updateBottomDistance(239, viewportHeight: 240)
        XCTAssertTrue(state.canShowUnreadButton)
        state.isUserScrolling = true
        XCTAssertFalse(state.canShowUnreadButton)
        state.isUserScrolling = false
        state.updateBottomDistance(84, viewportHeight: 240)
        XCTAssertFalse(state.canShowUnreadButton)
        state.updateBottomDistance(100, viewportHeight: 240)
        XCTAssertFalse(state.canShowUnreadButton)
        state.updateBottomDistance(500, viewportHeight: 240)
        state.resetForChatOpen()
        XCTAssertFalse(state.isFarFromBottom)
    }

    func testOlderSendDoesNotMatchANewerDraft() {
        XCTAssertTrue(ComposeDraft.matchesSubmitted("Hello", submitted: " Hello "))
        XCTAssertFalse(ComposeDraft.matchesSubmitted("New draft", submitted: "Hello"))
        XCTAssertFalse(ComposeDraft.matchesSubmitted(nil, submitted: "Hello"))
    }

    func testScrollingResetDoesNotLeaveComposerHidden() {
        var state = WatchChatScrollState()
        state.isUserScrolling = true
        state.resetForChatOpen()
        state.revealInitialMessages()
        XCTAssertTrue(state.canShowComposer)
    }

    func testSuggestionPreservesExistingDraft() {
        XCTAssertEqual(ComposeDraft.appending("Thanks!", to: "I'll call later."), "I'll call later. Thanks!")
        XCTAssertEqual(ComposeDraft.appending("👍", to: "Ready\n"), "Ready\n👍")
        XCTAssertEqual(ComposeDraft.appending("OK", to: ""), "OK")
    }

    func testSuggestionRespectsLimitWithoutDestroyingDraft() {
        XCTAssertEqual(ComposeDraft.appending("Thanks!", to: "hello", limit: 5), "hello")
        XCTAssertEqual(ComposeDraft.appending("👍👍", to: "", limit: 1), "👍")
    }
}
