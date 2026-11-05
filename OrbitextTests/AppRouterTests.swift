import XCTest
@testable import OrbitextWatch

@MainActor
final class AppRouterTests: XCTestCase {
    func testStartsEmpty() {
        let router = AppRouter()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testPushAppendsDestination() {
        let router = AppRouter()
        router.push(.settings)
        router.push(.chat(42))

        XCTAssertEqual(router.path.count, 2)
        XCTAssertEqual(router.path.last, .chat(42))
    }

    func testPopRemovesLast() {
        let router = AppRouter()
        router.push(.settings)
        router.push(.chat(1))
        router.pop()

        XCTAssertEqual(router.path, [.settings])
    }

    func testPopOnEmptyPathIsNoOp() {
        let router = AppRouter()
        router.pop()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testPopToRootClearsPath() {
        let router = AppRouter()
        router.push(.settings)
        router.push(.voiceRecorder(chatId: 1))
        router.push(.chat(7))
        router.popToRoot()

        XCTAssertTrue(router.path.isEmpty)
    }

    func testReplaceOverridesPath() {
        let router = AppRouter()
        router.push(.settings)
        router.replace(with: [.contacts, .chat(3)])

        XCTAssertEqual(router.path, [.contacts, .chat(3)])
    }

    func testChatRemainsOwnedWhileSystemEditorOrAttachmentCoversIt() {
        let router = AppRouter()
        router.openChat(42)
        XCTAssertTrue(router.containsChat(42))
        router.push(.attachments(chatId: 42))
        XCTAssertTrue(router.containsChat(42))
        router.popToRoot()
        XCTAssertFalse(router.containsChat(42))
    }

    func testSearchResultOwnsItsChatUntilRouteIsReplaced() {
        let router = AppRouter()
        let chat = ChatInfo(id: 42, title: "Sample", lastMessage: nil, unreadCount: 0,
                            photoFileId: nil, isGroup: false, isMuted: false, order: 0)
        router.replace(with: [.search, .searchResult(chat: chat, messageId: 100)])
        XCTAssertTrue(router.containsChat(42))
        router.openChat(43)
        XCTAssertFalse(router.containsChat(42))
        XCTAssertTrue(router.containsChat(43))
    }

    func testOpenChatFromRootSetsSingleChatDestination() {
        let router = AppRouter()
        router.openChat(42)

        XCTAssertEqual(router.path, [.chat(42)])
    }

    func testOpenChatFromAnyDepthReplacesPath() {
        let router = AppRouter()
        router.push(.settings)
        router.push(.voiceRecorder(chatId: 1))
        router.push(.contacts)
        router.openChat(99)

        XCTAssertEqual(router.path, [.chat(99)])
    }

    func testOpenChatViaChatInfoEquivalentToById() {
        let router = AppRouter()
        let chat = ChatInfo(
            id: 555,
            title: "Sample",
            lastMessage: nil,
            unreadCount: 0,
            photoFileId: nil,
            isGroup: false,
            isMuted: false,
            order: 0
        )
        router.openChat(chat)

        XCTAssertEqual(router.path, [.chat(555)])
    }

    // MARK: - Showing a chat from a chat

    /// A bot that links back to the chat it came from used to stack a second
    /// screen of it on the first, and so on for every hop.
    func testShowChatReturnsToTheScreenAlreadyShowingIt() {
        let router = AppRouter()
        router.replace(with: [.chat(1), .chat(2)])

        router.showChat(1, route: .chat(1))

        XCTAssertEqual(router.path, [.chat(1)])
    }

    func testShowChatPushesAChatNoScreenShows() {
        let router = AppRouter()
        router.replace(with: [.chat(1)])

        router.showChat(2, route: .chat(2))

        XCTAssertEqual(router.path, [.chat(1), .chat(2)])
    }

    func testPingPongBetweenTwoChatsNeverGrowsThePath() {
        let router = AppRouter()
        router.replace(with: [.chat(1)])

        for _ in 0..<6 {
            router.showChat(2, route: .chat(2))
            router.showChat(1, route: .chat(1))
        }
        router.showChat(2, route: .chat(2))

        XCTAssertEqual(router.path, [.chat(1), .chat(2)])
    }

    func testShowChatRecognisesEveryRouteThatShowsAChat() {
        let router = AppRouter()
        let chat = ChatInfo(id: 5, title: "Sample", lastMessage: nil, unreadCount: 0,
                            photoFileId: nil, isGroup: false, isMuted: false, order: 0)
        router.replace(with: [.search, .searchResult(chat: chat, messageId: 100), .chat(2)])

        router.showChat(5, route: .chat(5))
        XCTAssertEqual(router.path, [.search, .searchResult(chat: chat, messageId: 100)])

        router.replace(with: [.resolvedChat(chat), .chat(2)])
        router.showChat(5, route: .chat(5))
        XCTAssertEqual(router.path, [.resolvedChat(chat)])
    }

    /// Whatever sits above the chat goes with the screens on top of it.
    func testShowChatPopsTheScreensAboveTheChatItReturnsTo() {
        let router = AppRouter()
        router.replace(with: [.chat(1), .profile(ChatInfo.placeholder(id: 1)), .chat(2)])

        router.showChat(1, route: .chat(1))

        XCTAssertEqual(router.path, [.chat(1)])
    }

    func testShowChatReturnsToTheNearestScreenOfTheChat() {
        let router = AppRouter()
        router.replace(with: [.chat(1), .chat(2), .resolvedChat(ChatInfo.placeholder(id: 1)), .chat(3)])

        router.showChat(1, route: .chat(1))

        XCTAssertEqual(router.path.count, 3, "Only the screen on top of the nearest one is popped")
    }

    // MARK: - Observing the path

    func testEveryChangeToThePathIsReported() {
        let router = AppRouter()
        var reports = 0
        router.onPathChanged = { reports += 1 }

        router.push(.chat(1))
        router.push(.settings)
        router.pop()
        router.openChat(2)
        router.replace(with: [.contacts])
        router.popToRoot()

        XCTAssertEqual(reports, 6)
    }

    /// The navigation stack writes its binding on every update, usually with
    /// the path it already has.
    func testWritingThePathItAlreadyHasIsNotAChange() {
        let router = AppRouter()
        router.push(.chat(1))
        var reports = 0
        router.onPathChanged = { reports += 1 }

        router.path = [.chat(1)]
        router.popToRoot()
        router.popToRoot()

        XCTAssertEqual(reports, 1)
    }

    func testTheObserverSeesThePathAfterTheChange() {
        let router = AppRouter()
        var seen: [[AppDestination]] = []
        router.onPathChanged = { seen.append(router.path) }

        router.push(.chat(1))
        router.openChat(2)

        XCTAssertEqual(seen, [[.chat(1)], [.chat(2)]])
    }

    // MARK: - Deep-link URL parsing

    func testDeepLinkParsesValidChatURL() {
        let url = URL(string: "orbitext://chat/123")!
        XCTAssertEqual(AppRouter.chatId(fromDeepLink: url), 123)
    }

    func testDeepLinkParsesNegativeChatIds() {
        // Telegram chat ids can be negative (channels, supergroups).
        let url = URL(string: "orbitext://chat/-1001234567890")!
        XCTAssertEqual(AppRouter.chatId(fromDeepLink: url), -1001234567890)
    }

    func testDeepLinkRejectsUnknownScheme() {
        let url = URL(string: "https://chat/42")!
        XCTAssertNil(AppRouter.chatId(fromDeepLink: url))
    }

    func testDeepLinkRejectsUnknownHost() {
        let url = URL(string: "orbitext://other/42")!
        XCTAssertNil(AppRouter.chatId(fromDeepLink: url))
    }

    func testDeepLinkRejectsNonNumericId() {
        let url = URL(string: "orbitext://chat/abc")!
        XCTAssertNil(AppRouter.chatId(fromDeepLink: url))
    }

    func testDeepLinkRejectsMissingId() {
        let url = URL(string: "orbitext://chat/")!
        XCTAssertNil(AppRouter.chatId(fromDeepLink: url))
    }

    func testRouterIsObservable() {
        // @Observable types expose their stored properties via the
        // Observation framework. Mutating path should be observable -
        // we just exercise the type contract here; SwiftUI bindings
        // are covered by integration / UI tests.
        let router = AppRouter()
        router.push(.settings)
        router.push(.chat(1))

        XCTAssertEqual(router.path.count, 2)
    }

    func testIsTopChatMatchesOnlyTheVisibleChatRoute() {
        let router = AppRouter()
        let resolved = ChatInfo(id: 7, title: "Bot", lastMessage: nil, unreadCount: 0, photoFileId: nil, isGroup: false, isMuted: false, order: 0)

        XCTAssertFalse(router.isTopChat(1))
        router.push(.chat(1))
        XCTAssertTrue(router.isTopChat(1))
        router.push(.resolvedChat(resolved))
        XCTAssertFalse(router.isTopChat(1))
        XCTAssertTrue(router.isTopChat(7))
        XCTAssertTrue(router.containsChat(7))
        router.push(.contacts)
        XCTAssertFalse(router.isTopChat(7))
        router.replace(with: [.searchResult(chat: resolved, messageId: 3)])
        XCTAssertTrue(router.isTopChat(7))
    }
}
