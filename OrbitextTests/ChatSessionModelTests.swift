import XCTest
@testable import OrbitextWatch

/// What a chat screen's session means for TDLib, notifications and the
/// message store, apart from the view that drives it.
@MainActor
final class ChatSessionModelTests: XCTestCase {
    private let chatId: Int64 = 7

    func testEnterMarksTheChatActiveForNotificationsAndHistory() async {
        let rig = Rig(path: [.chat(7)])

        let entered = await rig.session.enter(chatId)

        XCTAssertTrue(entered)
        XCTAssertEqual(rig.service.openedChats, [7])
        XCTAssertEqual(rig.notifications.activeChatId, 7)
        XCTAssertEqual(rig.app.chatMessageStore.activeChatId, 7)
        XCTAssertEqual(rig.notifications.clearedChatIds, [7], "Delivered notifications of an open chat are removed")
    }

    func testEnterAfterTheRouteWasLeftDoesNotMarkTheChatActive() async {
        let rig = Rig(path: [])

        let entered = await rig.session.enter(chatId)

        XCTAssertFalse(entered)
        XCTAssertEqual(rig.service.openedChats, [7])
        XCTAssertEqual(rig.service.closedChats, [7], "The route was gone when TDLib answered: the open is paired with a close at once")
        XCTAssertNil(rig.notifications.activeChatId)
        XCTAssertNil(rig.app.chatMessageStore.activeChatId)
        XCTAssertTrue(rig.notifications.clearedChatIds.isEmpty)
    }

    func testEnterWhileCancelledDoesNotMarkTheChatActive() async {
        let rig = Rig(path: [.chat(7)])

        let enter = Task { await rig.session.enter(rig.chatId) }
        enter.cancel()
        let entered = await enter.value

        XCTAssertFalse(entered, "A screen that restarted its task owns the next session")
        XCTAssertNil(rig.notifications.activeChatId)
    }

    func testEnterWhileSignedOutDoesNotMarkTheChatActive() async {
        let rig = Rig(path: [.chat(7)])
        rig.app.authManager.authState = .waitPhoneNumber

        let entered = await rig.session.enter(chatId)

        XCTAssertFalse(entered)
        XCTAssertNil(rig.notifications.activeChatId)
    }

    // MARK: - Leaving

    func testSweepKeepsTheSessionWhileAScreenCoversTheChat() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        // A profile pushed over the chat disappears the chat view, but the
        // chat is still the user's place.
        rig.app.router.path = [.chat(7), .profile(rig.chat)]

        await rig.session.closeChatsLeftByRoute()

        XCTAssertTrue(rig.service.closedChats.isEmpty)
        XCTAssertEqual(rig.notifications.activeChatId, 7)
        XCTAssertEqual(rig.app.chatMessageStore.activeChatId, 7)
        XCTAssertEqual(rig.app.chatMessageStore.messages(for: chatId).map(\.id), [1], "History is kept for the way back")
    }

    func testSweepAfterLeavingTheRouteFreesTheChatAndClosesIt() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        rig.app.router.path = []

        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.closedChats, [7])
        XCTAssertNil(rig.notifications.activeChatId)
        XCTAssertNil(rig.app.chatMessageStore.activeChatId)
        XCTAssertTrue(rig.app.chatMessageStore.messages(for: chatId).isEmpty, "Leaving the chat frees its history")
    }

    func testSweepClosesTheChatOnlyOnce() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.app.router.path = []

        await rig.session.closeChatsLeftByRoute()
        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.closedChats, [7], "A second sweep has nothing left to close")
    }

    /// Nothing reads the history of a chat that was left, so a message of it
    /// is not kept, and does not wake the screen of the next chat.
    func testMessageOfAChatTheUserLeftIsNotKept() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        rig.app.router.path = []
        await rig.session.closeChatsLeftByRoute()

        rig.app.chatMessageStore.handleIncomingMessage(rig.message(id: 2))

        XCTAssertTrue(rig.app.chatMessageStore.messages(for: chatId).isEmpty)
    }

    func testSweepDoesNotClearAnotherChatsMarks() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        // A sibling chat took over through its own task before this one left.
        rig.notifications.activeChatId = 8
        rig.app.chatMessageStore.setActiveChat(8)
        rig.app.router.path = [.chat(8)]

        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.closedChats, [7])
        XCTAssertEqual(rig.notifications.activeChatId, 8)
        XCTAssertEqual(rig.app.chatMessageStore.activeChatId, 8)
    }

    func testSweepAfterSignOutEvenIfTheRouteRemains() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.app.authManager.authState = .waitPhoneNumber

        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.closedChats, [7])
        XCTAssertNil(rig.notifications.activeChatId)
    }

    func testEndAllClearsMarksWithoutClosingTheChat() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)

        rig.session.endAll()
        await rig.session.closeChatsLeftByRoute()

        XCTAssertNil(rig.notifications.activeChatId)
        XCTAssertNil(rig.app.chatMessageStore.activeChatId)
        XCTAssertTrue(rig.service.closedChats.isEmpty, "The client is gone; there is nothing to tell")
    }

    func testChatOpenedAfterTheSessionEndedIsOpenedInTDLibAgain() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.session.endAll()

        _ = await rig.session.enter(chatId)

        XCTAssertEqual(rig.service.openedChats, [7, 7], "The next account's client knows nothing of the first open")
    }

    // MARK: - Pairing openChat with the route

    /// TDLib counts opens: every return to a chat that sent another one
    /// left the count above zero for good, so the chat was never unloaded.
    func testReturningToACoveredChatDoesNotOpenItInTDLibAgain() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.app.router.path = [.chat(7), .profile(rig.chat)]
        await rig.session.closeChatsLeftByRoute()
        // The profile was popped: the chat view's task runs again.
        rig.app.router.path = [.chat(7)]
        _ = await rig.session.enter(chatId)
        rig.app.router.path = []

        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.openedChats, [7], "One open per stay in the chat")
        XCTAssertEqual(rig.service.closedChats, [7], "and one close when the route goes")
    }

    /// The covered chat's view had already disappeared when the route was
    /// replaced, so no disappear of it ever reported the exit.
    func testCoveredChatDroppedByAPathReplacementIsClosedAndFreed() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        let compose = ComposeTarget(chatId: 7, replyToId: nil, replyToSenderName: nil, replyToPreview: nil)
        rig.app.router.path = [.chat(7), .compose(compose)]
        await rig.session.closeChatsLeftByRoute()
        XCTAssertTrue(rig.service.closedChats.isEmpty)

        rig.app.router.openChat(9)
        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.closedChats, [7])
        XCTAssertTrue(rig.app.chatMessageStore.messages(for: chatId).isEmpty, "The dropped chat's history is freed")
    }

    func testTwoRoutesOfOneChatOpenItOnceAndCloseItWhenBothAreGone() async {
        let chat = ChatInfo(id: 7, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        let rig = Rig(path: [.chat(7), .resolvedChat(chat)])
        _ = await rig.session.enter(chatId)
        _ = await rig.session.enter(chatId)

        rig.app.router.path = [.chat(7)]
        await rig.session.closeChatsLeftByRoute()
        XCTAssertTrue(rig.service.closedChats.isEmpty, "The chat is still on screen once")

        rig.app.router.path = []
        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.openedChats, [7])
        XCTAssertEqual(rig.service.closedChats, [7])
    }

    /// A screen task that is cancelled while TDLib is being told would drop
    /// the open (a cancelled request is never sent), and the chat would then
    /// not be open for the rest of the stay.
    func testOpenIsNotCancelledWithTheScreenTaskThatAskedForIt() async {
        let double = RecordingChatCalls()
        let rig = Rig(path: [.chat(7)], service: double)

        let enter = Task { await rig.session.enter(rig.chatId) }
        enter.cancel()
        _ = await enter.value

        XCTAssertEqual(double.openWasCancelled, [false])
    }

    func testCloseIsNotCancelledWithTheCallerThatAskedForIt() async {
        let double = RecordingChatCalls()
        let rig = Rig(path: [.chat(7)], service: double)
        _ = await rig.session.enter(rig.chatId)
        rig.app.router.path = []

        let sweep = Task { await rig.session.closeChatsLeftByRoute() }
        sweep.cancel()
        await sweep.value

        XCTAssertEqual(double.closeWasCancelled, [false])
        XCTAssertEqual(rig.service.closedChats, [7])
    }

    /// The throttle may let a later request overtake an earlier one; a close
    /// that did would leave the open standing.
    func testCloseWaitsForAnOpenStillInFlight() async {
        let double = RecordingChatCalls()
        double.openGate = MockRequestGate()
        let rig = Rig(path: [.chat(7)], service: double)
        let entering = Task { await rig.session.enter(rig.chatId) }
        await waitUntil { double.openGate?.arrivals == 1 }
        rig.app.router.path = []

        let closing = Task { await rig.session.closeChatsLeftByRoute() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.service.closedChats.isEmpty, "The close was sent before the open it pairs with")

        double.openGate?.open()
        _ = await entering.value
        await closing.value

        XCTAssertEqual(double.log, ["open 7", "close 7"])
    }

    func testOpenWaitsForACloseStillInFlight() async {
        let double = RecordingChatCalls()
        let rig = Rig(path: [.chat(7)], service: double)
        _ = await rig.session.enter(rig.chatId)
        rig.app.router.path = []
        double.closeGate = MockRequestGate()
        let closing = Task { await rig.session.closeChatsLeftByRoute() }
        await waitUntil { double.closeGate?.arrivals == 1 }
        rig.app.router.path = [.chat(7)]

        let entering = Task { await rig.session.enter(rig.chatId) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(double.log, ["open 7", "close 7 (parked)"], "The reopen was sent before the close it follows")

        double.closeGate?.open()
        await closing.value
        _ = await entering.value

        XCTAssertEqual(double.log, ["open 7", "close 7 (parked)", "close 7", "open 7"])
    }

    /// A sweep that leaves several chats sends their closes one after the
    /// other, but all of them have to be known to the chain at once: a chat
    /// of the batch that is entered again while an earlier close is in flight
    /// must still open after its own close, or the late close shuts a chat
    /// that is on screen.
    func testChatEnteredAgainWhileAnEarlierChatsCloseIsInFlightOpensAfterItsOwnClose() async {
        let double = RecordingChatCalls()
        let rig = Rig(path: [.chat(7), .chat(8)], service: double)
        _ = await rig.session.enter(7)
        _ = await rig.session.enter(8)
        rig.app.router.path = []
        double.closeGate = MockRequestGate()
        let sweep = Task { await rig.session.closeChatsLeftByRoute() }
        await waitUntil { (double.closeGate?.arrivals ?? 0) >= 1 }
        // A deep link brings the user back to chat 8 while chat 7's close is
        // still in flight.
        rig.app.router.path = [.chat(8)]
        let entering = Task { await rig.session.enter(8) }
        try? await Task.sleep(for: .milliseconds(50))

        double.closeGate?.open()
        await sweep.value
        let entered = await entering.value

        XCTAssertTrue(entered)
        XCTAssertEqual(
            double.log.filter { $0.contains(" 8") },
            ["open 8", "close 8 (parked)", "close 8", "open 8"],
            "The reopen of chat 8 was sent before the close of its earlier stay"
        )
    }

    // MARK: - Client generations

    /// TDLib's count of opens lives in the client. A client that was replaced
    /// behind a standing route (TDLib closed and the app restarted it, or the
    /// server ended the session) starts every chat at zero, so a screen that
    /// comes back to the chat must open it again, not skip the open because
    /// the old client had one.
    func testChatOpenedBeforeTheClientWasReplacedIsOpenedAgain() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.clientGeneration = rig.service.clientGeneration.next()
        rig.app.router.path = [.chat(7), .profile(rig.chat)]
        await rig.session.closeChatsLeftByRoute()
        rig.app.router.path = [.chat(7)]

        _ = await rig.session.enter(chatId)
        rig.app.router.path = []
        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.service.openedChats, [7, 7], "The new client has not been told")
        XCTAssertEqual(rig.service.closedChats, [7], "One close, for the open the new client got")
    }

    /// The open of the ended client is not an open any more: there is
    /// nothing to close, and a close sent anyway would reach a client that
    /// never had the chat open.
    func testChatOpenedUnderAnEndedClientIsFreedButNotClosedOnTheNewOne() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        rig.service.clientGeneration = rig.service.clientGeneration.next()
        rig.app.router.path = []

        await rig.session.closeChatsLeftByRoute()

        XCTAssertTrue(rig.service.closedChats.isEmpty, "The client that had the chat open is gone")
        XCTAssertNil(rig.notifications.activeChatId)
        XCTAssertTrue(rig.app.chatMessageStore.messages(for: chatId).isEmpty, "The chat's history is still freed")
    }

    /// A call chained behind a slow one for the same chat runs after the
    /// session ended; it must not be sent with whatever client is current
    /// then, which is the next account's.
    func testCallQueuedBehindASlowOneIsNotSentToTheClientThatReplacedItsTarget() async {
        let double = RecordingChatCalls()
        let rig = Rig(path: [.chat(7)], service: double)
        _ = await rig.session.enter(rig.chatId)
        rig.app.router.path = []
        double.closeGate = MockRequestGate()
        let closing = Task { await rig.session.closeChatsLeftByRoute() }
        await waitUntil { (double.closeGate?.arrivals ?? 0) == 1 }
        rig.app.router.path = [.chat(7)]
        let entering = Task { await rig.session.enter(rig.chatId) }
        try? await Task.sleep(for: .milliseconds(50))
        // The user signs out while the close is still in flight: the client
        // is replaced and the session wiped.
        double.mock.clientGeneration = double.mock.clientGeneration.next()
        rig.session.endAll()

        double.closeGate?.open()
        await closing.value
        _ = await entering.value

        XCTAssertEqual(
            double.log, ["open 7", "close 7 (parked)", "close 7"],
            "The open queued behind the close was sent to the new account's client"
        )
    }

    // MARK: - History

    func testLoadHistoryFreesWhatTheChatHeldAndLoadsAgain() async {
        let rig = Rig(path: [.chat(7)])
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1), rig.message(id: 2)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1), rig.message(id: 2), rig.message(id: 3)]

        let result = await rig.session.loadHistory(chatId, scrollToMessageId: nil)

        XCTAssertEqual(result?.messages.map(\.id), [1, 2, 3])
        XCTAssertEqual(rig.app.chatMessageStore.messages(for: chatId).map(\.id), [1, 2, 3])
    }

    func testLoadHistoryReturnsNilWhenCancelled() async {
        let rig = Rig(path: [.chat(7)])
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]

        let load = Task { await rig.session.loadHistory(rig.chatId, scrollToMessageId: nil) }
        load.cancel()
        let result = await load.value

        XCTAssertNil(result, "A restarted screen must not scroll to the result of its old task")
    }

    // MARK: - What the chat left behind

    func testLeavingTheChatForgetsWhatItReportedAndWhatTheBotOffered() async {
        let rig = Rig(path: [.chat(7)])
        rig.service.botCommandsByChatId[7] = [BotCommandInfo(command: "start", description: "")]
        _ = await rig.session.enter(chatId)
        await rig.app.botKeyboardStore.load(chatId: 7)
        await rig.app.chatRepository.markMessageAsRead(chatId: 7, messageId: 1)
        XCTAssertEqual(rig.app.chatRepository.readReceiptMessageIdsByChat[7], [1])
        rig.app.router.path = []

        await rig.session.closeChatsLeftByRoute()

        XCTAssertNil(rig.app.chatRepository.readReceiptMessageIdsByChat[7])
        XCTAssertTrue(rig.app.botKeyboardStore.commands(for: 7).isEmpty)
    }

    func testChatCoveredByAnotherScreenKeepsItsBookkeeping() async {
        let rig = Rig(path: [.chat(7)])
        rig.service.botCommandsByChatId[7] = [BotCommandInfo(command: "start", description: "")]
        _ = await rig.session.enter(chatId)
        await rig.app.botKeyboardStore.load(chatId: 7)
        await rig.app.chatRepository.markMessageAsRead(chatId: 7, messageId: 1)
        rig.app.router.path = [.chat(7), .profile(rig.chat)]

        await rig.session.closeChatsLeftByRoute()

        XCTAssertEqual(rig.app.chatRepository.readReceiptMessageIdsByChat[7], [1])
        XCTAssertEqual(rig.app.botKeyboardStore.commands(for: 7).map(\.command), ["start"])
    }

    // MARK: - Reloading a screen that comes back

    func testScreenBackFromTheNativeEditorKeepsItsLoadedHistory() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)

        let reload = rig.session.needsHistoryLoad(chatId, loadedChatId: chatId, initialScrollDone: true)

        XCTAssertFalse(reload, "The editor covered the screen; its history and scroll position are still there")
    }

    func testScreenOpeningTheChatOrNotDoneLoadingLoadsTheHistory() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)

        XCTAssertTrue(rig.session.needsHistoryLoad(chatId, loadedChatId: nil, initialScrollDone: false))
        XCTAssertTrue(rig.session.needsHistoryLoad(chatId, loadedChatId: 8, initialScrollDone: true), "The task restarted for another chat")
        XCTAssertTrue(rig.session.needsHistoryLoad(chatId, loadedChatId: chatId, initialScrollDone: false), "A load that was cancelled midway")
    }

    func testChatWithoutMessagesIsNotLoadedAgainOnEveryReturn() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)

        XCTAssertFalse(rig.session.needsHistoryLoad(chatId, loadedChatId: chatId, initialScrollDone: true))
    }

    /// The background frees every chat but the open one, and the open one is
    /// the chat on top: the chat under it comes back with nothing to show,
    /// and a screen that skips the load because it loaded before keeps the
    /// blank list (and drops the live messages of the chat).
    func testChatCoveredByAnotherChatComesBackWithItsHistoryAfterABackground() async {
        let rig = Rig(path: [.chat(7), .chat(8)])
        rig.service.messagesByChatId[7] = [rig.message(id: 1), rig.message(id: 2)]
        _ = await rig.session.enter(7)
        _ = await rig.session.loadHistory(7, scrollToMessageId: nil)
        _ = await rig.session.enter(8)
        _ = await rig.session.loadHistory(8, scrollToMessageId: nil)
        rig.app.chatMessageStore.clearInactiveChats()
        XCTAssertTrue(rig.app.chatMessageStore.messages(for: 7).isEmpty)

        rig.app.router.pop()
        await rig.session.closeChatsLeftByRoute()
        _ = await rig.session.enter(7)
        let reload = rig.session.needsHistoryLoad(7, loadedChatId: 7, initialScrollDone: true)
        if reload {
            _ = await rig.session.loadHistory(7, scrollToMessageId: nil)
        }

        XCTAssertTrue(reload)
        XCTAssertEqual(rig.app.chatMessageStore.messages(for: 7).map(\.id), [1, 2])
        XCTAssertEqual(rig.service.closedChats, [8])
    }

    // MARK: - App wiring

    func testAppStateEndsTheChatSessionWhenTheSessionEnds() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)

        rig.app.clearLocalSessionData()

        XCTAssertNil(rig.notifications.activeChatId)
        XCTAssertNil(rig.app.chatMessageStore.activeChatId)
        XCTAssertTrue(rig.app.router.path.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.service.closedChats.isEmpty, "The client is gone; there is nothing to tell")
    }

    /// The server ended the session: the root view swaps the chat list for
    /// the sign-in screen and nothing pops the path, so no path change is
    /// left to report that the chat is gone.
    func testAccountLeavingTheReadyStateEndsTheChatSessionThoughTheRouteStands() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.service.messagesByChatId[chatId] = [rig.message(id: 1)]
        _ = await rig.session.loadHistory(chatId, scrollToMessageId: nil)
        // The sweep the rig's own path assignment queued must not be the one
        // that sees the sign-out.
        try? await Task.sleep(for: .milliseconds(50))

        rig.app.handleEvent(.authStateChanged(.closing))
        await waitUntil { !rig.service.closedChats.isEmpty }

        XCTAssertEqual(rig.app.router.path, [.chat(7)], "Nothing popped the path")
        XCTAssertEqual(rig.service.closedChats, [7])
        XCTAssertNil(rig.notifications.activeChatId, "The sign-in screen does not mute the chat")
        XCTAssertNil(rig.app.chatMessageStore.activeChatId)
        XCTAssertTrue(rig.app.chatMessageStore.messages(for: chatId).isEmpty, "The signed-out account's history is freed")
    }

    func testChatTheRouteStillHoldsIsOpenedAgainAfterSigningInAgain() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        try? await Task.sleep(for: .milliseconds(50))
        rig.app.handleEvent(.authStateChanged(.closing))
        await waitUntil { !rig.service.closedChats.isEmpty }

        // The chat list is rebuilt over the path that was left standing.
        rig.app.handleEvent(.authStateChanged(.ready))
        let entered = await rig.session.enter(chatId)

        XCTAssertTrue(entered)
        XCTAssertEqual(rig.service.openedChats, [7, 7], "The chat was not open in the session that followed")
        XCTAssertEqual(rig.notifications.activeChatId, 7)
    }

    func testReadyStateEventLeavesTheChatSessionAlone() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)

        rig.app.handleEvent(.authStateChanged(.ready))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(rig.service.closedChats.isEmpty)
        XCTAssertEqual(rig.notifications.activeChatId, 7)
    }

    func testLeavingTheChatRouteClosesTheChatInTDLib() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)

        rig.app.router.pop()
        await waitUntil { !rig.service.closedChats.isEmpty }

        XCTAssertEqual(rig.service.closedChats, [7])
    }

    func testReplacingThePathClosesTheChatItCovered() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)
        rig.app.router.push(.attachments(chatId: 7))

        rig.app.router.openChat(9)
        await waitUntil { !rig.service.closedChats.isEmpty }

        XCTAssertEqual(rig.service.closedChats, [7])
    }

    func testPushingAScreenOverTheChatLeavesItOpen() async {
        let rig = Rig(path: [.chat(7)])
        _ = await rig.session.enter(chatId)

        rig.app.router.push(.profile(rig.chat))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(rig.service.closedChats.isEmpty)
    }

    // MARK: - Rig

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// What TDLib was told, in what order, and whether the caller's task was
    /// cancelled when it was. Either call can be held until a test opens it.
    @MainActor
    private final class RecordingChatCalls: ForwardingTelegramService {
        var openWasCancelled: [Bool] = []
        var closeWasCancelled: [Bool] = []
        var log: [String] = []
        var openGate: MockRequestGate?
        var closeGate: MockRequestGate?

        override func openChat(_ chatId: Int64) async {
            openWasCancelled.append(Task.isCancelled)
            await openGate?.pass()
            log.append("open \(chatId)")
            await mock.openChat(chatId)
        }

        override func closeChat(_ chatId: Int64) async {
            closeWasCancelled.append(Task.isCancelled)
            if let closeGate {
                log.append("close \(chatId) (parked)")
                await closeGate.pass()
            }
            log.append("close \(chatId)")
            await mock.closeChat(chatId)
        }
    }

    @MainActor
    private struct Rig {
        let chatId: Int64 = 7
        let service: MockTelegramService
        let notifications = MockNotificationManager()
        let app: AppState
        var session: ChatSessionModel { app.chatSession }
        let chat = ChatInfo(id: 7, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)

        init(path: [AppDestination]) {
            self.init(path: path, mock: MockTelegramService(), transport: nil)
        }

        /// A transport double that wraps the mock the test reads.
        init(path: [AppDestination], service double: ForwardingTelegramService) {
            self.init(path: path, mock: double.mock, transport: double)
        }

        private init(path: [AppDestination], mock: MockTelegramService, transport: (any TelegramServiceProtocol)?) {
            service = mock
            ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
            app = AppState(
                service: transport ?? mock,
                notificationManager: notifications,
                widgetSync: MockWidgetSync(),
                preferences: AppPreferencesStore(defaults: makeTestDefaults())
            )
            app.networkMonitor.pause()
            app.authManager.authState = .ready
            app.router.path = path
        }

        func message(id: Int64) -> MessageInfo {
            MessageInfo(
                id: id, chatId: chatId, senderName: "Alice", senderId: 2,
                content: .text(FormattedString(text: "Hi \(id)")), date: Date(),
                isOutgoing: false, isRead: false
            )
        }
    }
}
