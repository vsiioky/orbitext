import XCTest
@testable import OrbitextWatch

/// One-shot gate: an async caller parks in `wait()` until the test calls
/// `release()`. `hasArrived` lets the test know the caller is parked.
private final class BotStoreGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var released = false

    var hasArrived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return arrived
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrived = true
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Wraps MockTelegramService but lets getReplyMarkupMessage read its answer
/// first and then suspend, so a test can change store state while a load is
/// still in flight and finish the load afterwards with the older answer.
@MainActor
private final class BotStoreGatedService: ForwardingTelegramService {
    nonisolated let markupGate = BotStoreGate()

    override func getReplyMarkupMessage(chatId: Int64) async throws -> MessageInfo? {
        let answer = try await mock.getReplyMarkupMessage(chatId: chatId)
        await markupGate.wait()
        return answer
    }
}

@MainActor
final class BotKeyboardStoreTests: XCTestCase {
    private var service: MockTelegramService!
    private var store: BotKeyboardStore!

    override func setUp() async throws {
        try await super.setUp()
        service = MockTelegramService()
        store = BotKeyboardStore(service: service)
    }

    // MARK: - Fixtures

    private let chatId: Int64 = 1

    private func keyboard(_ labels: String..., oneTime: Bool = false) -> ReplyMarkup {
        .showKeyboard(ReplyKeyboard(
            rows: [labels.map { ReplyKeyboardButton(text: $0, kind: .text) }],
            isOneTime: oneTime
        ))
    }

    private func message(id: Int64, markup: ReplyMarkup?, chatId: Int64 = 1) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: chatId,
            senderName: "Bot",
            senderId: 99,
            content: .text("Menu"),
            date: Date(),
            isOutgoing: false,
            isRead: false,
            replyMarkup: markup
        )
    }

    private func commands(_ names: String...) -> [BotCommandInfo] {
        names.map { BotCommandInfo(command: $0, description: "") }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: - release

    /// The map kept the command menu of every chat that was opened, bots and
    /// not: an empty one for each of the rest.
    func testReleasedChatForgetsItsCommandsAndLoadsThemAgainOnTheNextOpen() async {
        service.botCommandsByChatId[chatId] = commands("start", "help")
        await store.load(chatId: chatId)
        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start", "help"])

        store.release(chatId: chatId)

        XCTAssertTrue(store.commands(for: chatId).isEmpty)
        await store.load(chatId: chatId)
        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start", "help"])
    }

    func testReleaseLeavesTheOtherChatsCommands() async {
        service.botCommandsByChatId[1] = commands("one")
        service.botCommandsByChatId[2] = commands("two")
        await store.load(chatId: 1)
        await store.load(chatId: 2)

        store.release(chatId: 1)

        XCTAssertEqual(store.commands(for: 2).map(\.command), ["two"])
    }

    /// The revision counter is what stops a slow load from overwriting a
    /// newer live change. Releasing the chat resets it, so the counter alone
    /// no longer separates the load from a later change; the screen that
    /// asked is gone by then and its load is cancelled, which it also checks.
    func testCancelledLoadStartedBeforeReleaseDoesNotOverwriteALaterLiveChange() async {
        let gated = BotStoreGatedService()
        gated.mock.replyMarkupMessagesByChatId[chatId] = message(id: 10, markup: keyboard("Old"))
        let gatedStore = BotKeyboardStore(service: gated)
        gatedStore.handleReplyMarkupChanged(chatId: chatId, message: message(id: 9, markup: keyboard("Earlier")))
        let load = Task { await gatedStore.load(chatId: chatId) }
        let arrived = await waitUntil { gated.markupGate.hasArrived }
        XCTAssertTrue(arrived)

        gatedStore.release(chatId: chatId)
        gatedStore.handleReplyMarkupChanged(chatId: chatId, message: message(id: 11, markup: keyboard("New")))
        load.cancel()
        gated.markupGate.release()
        await load.value

        XCTAssertEqual(gatedStore.replyKeyboard(for: chatId)?.messageId, 11)
    }

    // MARK: - load

    func testLoadPopulatesReplyKeyboardAndCommands() async throws {
        let markup = keyboard("Yes", "No")
        service.replyMarkupMessagesByChatId[chatId] = message(id: 10, markup: markup)
        service.botCommandsByChatId[chatId] = commands("start", "help")

        await store.load(chatId: chatId)

        let loaded = try XCTUnwrap(store.replyKeyboard(for: chatId))
        XCTAssertEqual(loaded.messageId, 10)
        XCTAssertEqual(loaded.markup, markup)
        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start", "help"])
        XCTAssertTrue(store.hasMenu(for: chatId))
    }

    func testLoadForChatWithoutBotStateLeavesEverythingEmpty() async {
        await store.load(chatId: chatId)

        XCTAssertNil(store.replyKeyboard(for: chatId))
        XCTAssertTrue(store.commands(for: chatId).isEmpty)
        XCTAssertFalse(store.hasMenu(for: chatId))
    }

    func testLoadClearsAPreviousKeyboardWhenTheChatNoLongerHasOne() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("Yes")))

        await store.load(chatId: chatId)

        XCTAssertNil(store.replyKeyboard(for: chatId))
    }

    func testLoadIgnoresMarkupThatDoesNotStayActiveInTheChat() async {
        let inline = ReplyMarkup.inlineKeyboard([[InlineKeyboardButton(text: "A", action: .buy)]])
        service.replyMarkupMessagesByChatId[chatId] = message(id: 10, markup: inline)

        await store.load(chatId: chatId)

        XCTAssertNil(store.replyKeyboard(for: chatId))
    }

    func testLoadKeepsForceReplyRequest() async throws {
        service.replyMarkupMessagesByChatId[chatId] = message(id: 11, markup: .forceReply(placeholder: "Your name"))

        await store.load(chatId: chatId)

        let loaded = try XCTUnwrap(store.replyKeyboard(for: chatId))
        XCTAssertEqual(loaded.forceReplyPlaceholder, "Your name")
    }

    func testLoadErrorOnReplyMarkupKeepsPreviousKeyboardButStillSetsCommands() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 5, markup: keyboard("Old")))
        service.replyMarkupMessageError = TestError.failed("keyboard unavailable")
        service.botCommandsByChatId[chatId] = commands("start")

        await store.load(chatId: chatId)

        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 5)
        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start"])
    }

    func testLoadErrorOnCommandsKeepsPreviousCommandsButStillSetsKeyboard() async {
        service.botCommandsByChatId[chatId] = commands("start")
        await store.load(chatId: chatId)
        service.botCommandsError = TestError.failed("commands unavailable")
        service.replyMarkupMessagesByChatId[chatId] = message(id: 12, markup: keyboard("Fresh"))

        await store.load(chatId: chatId)

        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start"])
        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 12)
    }

    func testLoadReplacesCommandsWithAnEmptyMenu() async {
        service.botCommandsByChatId[chatId] = commands("start")
        await store.load(chatId: chatId)
        service.botCommandsByChatId[chatId] = []

        await store.load(chatId: chatId)

        XCTAssertTrue(store.commands(for: chatId).isEmpty)
    }

    func testStateIsTrackedPerChat() async {
        service.replyMarkupMessagesByChatId[1] = message(id: 10, markup: keyboard("One"))
        service.botCommandsByChatId[2] = commands("two")

        await store.load(chatId: 1)
        await store.load(chatId: 2)

        XCTAssertNotNil(store.replyKeyboard(for: 1))
        XCTAssertNil(store.replyKeyboard(for: 2))
        XCTAssertTrue(store.commands(for: 1).isEmpty)
        XCTAssertEqual(store.commands(for: 2).map(\.command), ["two"])
    }

    // MARK: - handleReplyMarkupChanged

    func testHandleReplyMarkupChangedSetsKeyboard() {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 20, markup: keyboard("A")))

        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 20)
    }

    func testHandleReplyMarkupChangedWithNilClearsKeyboard() {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 20, markup: keyboard("A")))

        store.handleReplyMarkupChanged(chatId: chatId, message: nil)

        XCTAssertNil(store.replyKeyboard(for: chatId))
    }

    func testHandleReplyMarkupChangedWithRemoveKeyboardMarkupClears() {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 20, markup: keyboard("A")))

        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 21, markup: .removeKeyboard))

        XCTAssertNil(store.replyKeyboard(for: chatId))
    }

    func testHandleReplyMarkupChangedKeepsCommands() async {
        service.botCommandsByChatId[chatId] = commands("start")
        await store.load(chatId: chatId)

        store.handleReplyMarkupChanged(chatId: chatId, message: nil)

        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start"])
    }

    func testLoadStartedAfterALiveChangeStillApplies() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 30, markup: keyboard("Live")))
        service.replyMarkupMessagesByChatId[chatId] = message(id: 3, markup: keyboard("Older"))

        await store.load(chatId: chatId)

        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 3)
    }

    // MARK: - Stale loads

    private func makeGatedStore() -> (store: BotKeyboardStore, service: BotStoreGatedService) {
        let gated = BotStoreGatedService()
        return (BotKeyboardStore(service: gated), gated)
    }

    func testLoadStartedBeforeALiveChangeCannotOverwriteIt() async {
        let (gatedStore, gated) = makeGatedStore()
        gated.mock.replyMarkupMessagesByChatId[chatId] = message(id: 3, markup: keyboard("Stale"))
        gated.mock.botCommandsByChatId[chatId] = commands("start")
        let load = Task { await gatedStore.load(chatId: self.chatId) }
        let parked = await waitUntil { gated.markupGate.hasArrived }
        XCTAssertTrue(parked, "load never reached getReplyMarkupMessage")

        gatedStore.handleReplyMarkupChanged(chatId: chatId, message: message(id: 9, markup: keyboard("Fresh")))
        gated.markupGate.release()
        await load.value

        XCTAssertEqual(gatedStore.replyKeyboard(for: chatId)?.messageId, 9)
        XCTAssertEqual(gatedStore.commands(for: chatId).map(\.command), ["start"], "commands are not subject to the keyboard revision")
    }

    func testLoadStartedBeforeALiveRemovalCannotBringTheKeyboardBack() async {
        let (gatedStore, gated) = makeGatedStore()
        gated.mock.replyMarkupMessagesByChatId[chatId] = message(id: 3, markup: keyboard("Stale"))
        let load = Task { await gatedStore.load(chatId: self.chatId) }
        let parked = await waitUntil { gated.markupGate.hasArrived }
        XCTAssertTrue(parked, "load never reached getReplyMarkupMessage")

        gatedStore.handleReplyMarkupChanged(chatId: chatId, message: nil)
        gated.markupGate.release()
        await load.value

        XCTAssertNil(gatedStore.replyKeyboard(for: chatId))
    }

    func testLoadStartedBeforeConsumeCannotBringTheKeyboardBack() async {
        let (gatedStore, gated) = makeGatedStore()
        let live = message(id: 10, markup: keyboard("Once", oneTime: true))
        gatedStore.handleReplyMarkupChanged(chatId: chatId, message: live)
        gated.mock.replyMarkupMessagesByChatId[chatId] = live
        let load = Task { await gatedStore.load(chatId: self.chatId) }
        let parked = await waitUntil { gated.markupGate.hasArrived }
        XCTAssertTrue(parked, "load never reached getReplyMarkupMessage")

        await gatedStore.consumeReplyKeyboard(chatId: chatId, messageId: 10)
        gated.markupGate.release()
        await load.value

        // The stale load carries the uncollapsed keyboard; the consumed
        // (collapsed) state must win.
        XCTAssertEqual(gatedStore.replyKeyboard(for: chatId)?.keyboard?.isCollapsed, true)
        XCTAssertEqual(gatedStore.replyKeyboard(for: chatId)?.isAwaitingInput, false)
        XCTAssertEqual(gated.mock.deletedReplyMarkups.count, 1)
    }

    // MARK: - consumeReplyKeyboard

    func testConsumeDeletesReplyMarkupAndCollapsesOneTimeKeyboard() async throws {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("Once", oneTime: true)))

        await store.consumeReplyKeyboard(chatId: chatId, messageId: 10)

        XCTAssertEqual(service.deletedReplyMarkups.count, 1)
        XCTAssertEqual(service.deletedReplyMarkups.first?.chatId, chatId)
        XCTAssertEqual(service.deletedReplyMarkups.first?.messageId, 10)
        // TDLib keeps a used one-time keyboard (is_personal = false), so it
        // stays reachable from the menu but no longer awaits input.
        let active = try XCTUnwrap(store.replyKeyboard(for: chatId))
        XCTAssertEqual(active.keyboard?.isCollapsed, true)
        XCTAssertFalse(active.isAwaitingInput)
        XCTAssertNil(active.placeholder)
        XCTAssertTrue(store.hasMenu(for: chatId))
    }

    func testConsumeClearsAnsweredForceReply() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 12, markup: .forceReply(placeholder: "Name")))

        await store.consumeReplyKeyboard(chatId: chatId, messageId: 12)

        XCTAssertNil(store.replyKeyboard(for: chatId))
        XCTAssertEqual(service.deletedReplyMarkups.map(\.messageId), [12])
    }

    func testTDLibFollowUpForConsumedOneTimeKeyboardKeepsItCollapsed() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("Once", oneTime: true)))
        await store.consumeReplyKeyboard(chatId: chatId, messageId: 10)

        // deleteChatReplyMarkup answers with the same keyboard, is_personal = false.
        let followUp = ReplyMarkup.showKeyboard(ReplyKeyboard(
            rows: [[ReplyKeyboardButton(text: "Once", kind: .text)]],
            isOneTime: true,
            isPersonal: false
        ))
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: followUp))

        XCTAssertEqual(store.replyKeyboard(for: chatId)?.isAwaitingInput, false)
    }

    func testConsumeWithDifferentMessageIdDoesNothing() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("Once", oneTime: true)))

        await store.consumeReplyKeyboard(chatId: chatId, messageId: 99)

        XCTAssertTrue(service.deletedReplyMarkups.isEmpty)
        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 10)
    }

    func testConsumeWithoutAnActiveKeyboardDoesNothing() async {
        await store.consumeReplyKeyboard(chatId: chatId, messageId: 10)

        XCTAssertTrue(service.deletedReplyMarkups.isEmpty)
    }

    func testConsumeOnlyAffectsTheGivenChat() async {
        store.handleReplyMarkupChanged(chatId: 1, message: message(id: 10, markup: keyboard("A"), chatId: 1))
        store.handleReplyMarkupChanged(chatId: 2, message: message(id: 10, markup: keyboard("B"), chatId: 2))

        await store.consumeReplyKeyboard(chatId: 1, messageId: 10)

        XCTAssertNil(store.replyKeyboard(for: 1))
        XCTAssertEqual(store.replyKeyboard(for: 2)?.messageId, 10)
        XCTAssertEqual(service.deletedReplyMarkups.map(\.chatId), [1])
    }

    func testConsumeKeepsCommands() async {
        service.botCommandsByChatId[chatId] = commands("start")
        service.replyMarkupMessagesByChatId[chatId] = message(id: 10, markup: keyboard("Once", oneTime: true))
        await store.load(chatId: chatId)

        await store.consumeReplyKeyboard(chatId: chatId, messageId: 10)

        XCTAssertEqual(store.commands(for: chatId).map(\.command), ["start"])
        XCTAssertTrue(store.hasMenu(for: chatId))
    }

    // MARK: - hasMenu

    func testHasMenuIsFalseWithoutKeyboardOrCommands() {
        XCTAssertFalse(store.hasMenu(for: chatId))
    }

    func testHasMenuIsTrueForKeyboardOnly() {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("A")))

        XCTAssertTrue(store.hasMenu(for: chatId))
    }

    func testHasMenuIsTrueForCommandsOnly() async {
        service.botCommandsByChatId[chatId] = commands("start")

        await store.load(chatId: chatId)

        XCTAssertTrue(store.hasMenu(for: chatId))
    }

    func testHasMenuIsFalseForForceReplyOnly() {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: .forceReply(placeholder: "Name")))

        XCTAssertNotNil(store.replyKeyboard(for: chatId))
        XCTAssertFalse(store.hasMenu(for: chatId))
    }

    func testHasMenuIsPerChat() {
        store.handleReplyMarkupChanged(chatId: 1, message: message(id: 10, markup: keyboard("A")))

        XCTAssertTrue(store.hasMenu(for: 1))
        XCTAssertFalse(store.hasMenu(for: 2))
    }

    // MARK: - resetAll

    func testResetAllClearsKeyboardsAndCommandsForEveryChat() async {
        service.replyMarkupMessagesByChatId[1] = message(id: 10, markup: keyboard("A"), chatId: 1)
        service.botCommandsByChatId[2] = commands("two")
        await store.load(chatId: 1)
        await store.load(chatId: 2)

        store.resetAll()

        XCTAssertNil(store.replyKeyboard(for: 1))
        XCTAssertTrue(store.commands(for: 2).isEmpty)
        XCTAssertFalse(store.hasMenu(for: 1))
        XCTAssertFalse(store.hasMenu(for: 2))
    }

    func testStoreIsUsableAfterResetAll() async {
        store.handleReplyMarkupChanged(chatId: chatId, message: message(id: 10, markup: keyboard("A")))
        store.resetAll()
        service.replyMarkupMessagesByChatId[chatId] = message(id: 11, markup: keyboard("B"))

        await store.load(chatId: chatId)

        XCTAssertEqual(store.replyKeyboard(for: chatId)?.messageId, 11)
    }
}
