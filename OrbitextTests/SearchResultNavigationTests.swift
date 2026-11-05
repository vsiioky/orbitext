import XCTest
@testable import OrbitextWatch

@MainActor
final class SearchResultNavigationTests: XCTestCase {
    func testUncachedChannelResolvesActualChatBeforeRoutingSearchHit() async {
        let service = MockTelegramService()
        let selection = SearchResultNavigation()
        let router = AppRouter()
        router.path = [.search]
        let channel = Self.chat(id: -100_042, title: "Actual channel", isChannel: true)
        service.chatsById[channel.id] = channel

        await selection.open(message: Self.message(chatId: channel.id), cachedChat: nil, service: service, router: router)

        XCTAssertEqual(service.getChatRequests, [channel.id])
        guard case .searchResult(let routed, let messageId) = router.path.last else { return XCTFail("Expected resolved search route") }
        XCTAssertEqual(routed.id, channel.id)
        XCTAssertEqual(routed.title, "Actual channel")
        XCTAssertTrue(routed.isChannel, "A channel outside the current folder must not expose the private-chat composer/profile")
        XCTAssertEqual(messageId, 901)
        XCTAssertNil(selection.loadingKey)
        XCTAssertNil(selection.failedKey)
        XCTAssertTrue(service.getChatsRequests.isEmpty, "Opening one result must not reload or replace the visible folder")
    }

    func testCachedGroupRoutesWithoutAnotherServiceRequestAndOnlyOnce() async {
        let service = MockTelegramService()
        let selection = SearchResultNavigation()
        let router = AppRouter()
        let group = Self.chat(id: -43, title: "Known group", isGroup: true)

        for _ in 0..<2 {
            await selection.open(message: Self.message(chatId: group.id), cachedChat: group, service: service, router: router)
        }

        XCTAssertEqual(router.path.count, 1)
        guard case .searchResult(let routed, _) = router.path.first else { return XCTFail("Expected search route") }
        XCTAssertTrue(routed.isGroup)
        XCTAssertTrue(service.getChatRequests.isEmpty)
    }

    func testCancelledFetchCannotRouteEvenWhenServiceReturnsAChat() async {
        let service = Self.delayedService()
        let selection = SearchResultNavigation()
        let router = AppRouter()
        let request = Task { await selection.open(message: Self.message(chatId: 42), cachedChat: nil, service: service, router: router) }
        await waitForRequest(service)
        request.cancel()
        await request.value

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNil(selection.loadingKey)
        XCTAssertNil(selection.failedKey)
    }

    func testNewSelectionWinsOverDelayedOldSelection() async {
        let service = Self.delayedService()
        let selection = SearchResultNavigation()
        let router = AppRouter()
        let old = Task { await selection.open(message: Self.message(chatId: 42), cachedChat: nil, service: service, router: router) }
        await waitForRequest(service)
        let selected = Self.chat(id: 43, title: "New selection", isGroup: true)

        await selection.open(message: Self.message(chatId: 43), cachedChat: selected, service: service, router: router)
        await old.value

        XCTAssertEqual(router.path, [.searchResult(chat: selected, messageId: 901)])
        XCTAssertNil(selection.loadingKey)
        XCTAssertNil(selection.failedKey)
    }

    func testLeavingSearchInvalidatesUncancelledLateCompletion() async {
        let service = Self.delayedService()
        let selection = SearchResultNavigation()
        let router = AppRouter()
        let request = Task { await selection.open(message: Self.message(chatId: 42), cachedChat: nil, service: service, router: router) }
        await waitForRequest(service)

        selection.cancel()
        router.replace(with: [.settings])
        await request.value

        XCTAssertEqual(router.path, [.settings])
        XCTAssertNil(selection.loadingKey)
        XCTAssertNil(selection.failedKey)
    }

    func testResolutionFailureKeepsSearchRouteAndAllowsExplicitRetry() async {
        // An unstarted service fails before any native request is sent.
        let unavailable = TDLibService()
        defer { unavailable.session.finishEventsForTesting() }
        let selection = SearchResultNavigation()
        let router = AppRouter()
        router.path = [.search]
        let message = Self.message(chatId: 42)

        await selection.open(message: message, cachedChat: nil, service: unavailable, router: router)

        XCTAssertEqual(router.path, [.search])
        XCTAssertEqual(selection.failedKey, MessageKey(chatId: 42, messageId: 901))
        XCTAssertNil(selection.loadingKey)
        let available = MockTelegramService()
        let chat = Self.chat(id: 42, title: "Resolved on retry")
        available.chatsById[42] = chat

        await selection.open(message: message, cachedChat: nil, service: available, router: router)

        XCTAssertEqual(router.path, [.search, .searchResult(chat: chat, messageId: 901)])
        XCTAssertNil(selection.failedKey)
    }

    func testMismatchedResponseCannotOpenDifferentChat() async {
        let service = MockTelegramService()
        service.chatsById[42] = Self.chat(id: 43, title: "Different chat")
        let selection = SearchResultNavigation()
        let router = AppRouter()

        await selection.open(message: Self.message(chatId: 42), cachedChat: nil, service: service, router: router)

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(selection.failedKey, MessageKey(chatId: 42, messageId: 901))
    }

    func testStaleInvalidResponseCannotReplaceNewSelectionsState() async {
        let service = Self.delayedService()
        service.chatsById[42] = Self.chat(id: 99, title: "Stale wrong response")
        let selection = SearchResultNavigation()
        let router = AppRouter()
        let request = Task { await selection.open(message: Self.message(chatId: 42), cachedChat: nil, service: service, router: router) }
        await waitForRequest(service)
        let selected = Self.chat(id: 43, title: "Chosen chat")
        await selection.open(message: Self.message(chatId: 43), cachedChat: selected, service: service, router: router)
        await request.value

        XCTAssertEqual(router.path, [.searchResult(chat: selected, messageId: 901)])
        XCTAssertNil(selection.failedKey)
    }

    private static func delayedService() -> MockTelegramService {
        let service = MockTelegramService()
        service.getChatDelay = .milliseconds(150)
        service.chatsById[42] = chat(id: 42, title: "Slow chat")
        return service
    }

    private func waitForRequest(_ service: MockTelegramService) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while service.getChatRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(service.getChatRequests.isEmpty)
    }

    private static func chat(id: Int64, title: String, isGroup: Bool = false, isChannel: Bool = false) -> ChatInfo {
        ChatInfo(id: id, title: title, lastMessage: nil, unreadCount: 0,
                 isGroup: isGroup, isChannel: isChannel, isMuted: false, order: 1)
    }

    private static func message(chatId: Int64) -> MessageInfo {
        MessageInfo(id: 901, chatId: chatId, senderName: "Message author, not chat title", senderId: 123,
                    content: .text("Offline search fixture"), date: .distantPast, isOutgoing: false, isRead: true)
    }
}
