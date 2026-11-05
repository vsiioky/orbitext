import XCTest
@testable import OrbitextWatch

/// Pin and mute are what the user asked for, shown until TDLib answers. They
/// live in the repository's store; TDLib's mirror in the transport only ever
/// holds what TDLib reported.
@MainActor
final class ChatPinMuteTests: XCTestCase {
    private var service: MockTelegramService!
    private var repo: ChatRepository!

    override func setUp() async throws {
        ListCache<ChatInfo>(filename: "cached_chats.json").clear()
        service = MockTelegramService()
        repo = makeRepository(service: service)
    }

    override func tearDown() async throws {
        repo?.folderChatListCaches.values.forEach { $0.clear() }
        repo?.chatListCache.clear()
        repo = nil
        service = nil
    }

    func testFailedPinRevertsRowAndLeavesTransportMirrorUntouched() async {
        // The service was never started, so the request fails at once.
        let native = TDLibService()
        let repo = makeRepository(service: native)
        defer { repo.chatListCache.clear() }
        let mirrored = ChatInfo(
            id: 1, title: "Chat 1", lastMessage: nil, unreadCount: 0,
            isGroup: false, isMuted: false, order: 50, isPinned: true
        )
        native.chatCache.set(1, mirrored)
        // The row on screen disagrees with the mirror, as it can between events.
        repo.chats = [chat(1, order: 50)]

        do {
            try await repo.pinChat(chatId: 1, isPinned: true)
            XCTFail("the unstarted service must reject the request")
        } catch {}

        XCTAssertEqual(repo.chats.first?.isPinned, false, "the row goes back to what it was")
        XCTAssertEqual(native.chatCache.get(1)?.isPinned, true, "the mirror is TDLib's, not the user's intent")
    }

    func testFailedMuteLeavesTransportMirrorUntouched() async {
        let native = TDLibService()
        let repo = makeRepository(service: native)
        defer { repo.chatListCache.clear() }
        var mirrored = chat(1, order: 50)
        mirrored.isMuted = true
        native.chatCache.set(1, mirrored)
        repo.chats = [chat(1, order: 50)]

        do {
            try await repo.muteChat(chatId: 1, isMuted: true)
            XCTFail("the unstarted service must reject the request")
        } catch {}

        XCTAssertEqual(repo.chats.first?.isMuted, false)
        XCTAssertEqual(native.chatCache.get(1)?.isMuted, true)
    }

    func testPinOverlaySurvivesStaleSnapshotUntilPositionUpdate() async throws {
        repo.chats = [chat(1, order: 10)]

        try await repo.pinChat(chatId: 1, isPinned: true)
        XCTAssertEqual(repo.chats.first?.isPinned, true)

        // A field snapshot from before the request does not undo it.
        repo.handleChatUpdate(chat(1, order: 10))
        XCTAssertEqual(repo.chats.first?.isPinned, true)

        // TDLib's position update is the answer.
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 900), positions: [ChatListPosition(list: .main, order: 900, isPinned: true)],
            source: .explicitPosition
        ))
        XCTAssertEqual(repo.chats.first?.isPinned, true)
        XCTAssertEqual(repo.chats.first?.order, 900)

        // From then on the list follows TDLib again, including a later unpin.
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 10), positions: [ChatListPosition(list: .main, order: 10, isPinned: false)],
            source: .explicitPosition
        ))
        XCTAssertEqual(repo.chats.first?.isPinned, false)
    }

    func testMuteOverlayHoldsUntilTheChatSnapshotAgrees() async throws {
        repo.chats = [chat(1, order: 10)]

        try await repo.muteChat(chatId: 1, isMuted: true)
        repo.handleChatUpdate(chat(1, order: 10))
        XCTAssertEqual(repo.chats.first?.isMuted, true)

        var muted = chat(1, order: 10)
        muted.isMuted = true
        repo.handleChatUpdate(muted)
        repo.handleChatUpdate(chat(1, order: 10))
        XCTAssertEqual(repo.chats.first?.isMuted, false, "once TDLib has agreed, it is TDLib's value again")
    }

    func testPinInFolderTargetsTheFolderList() async throws {
        repo.chats = [chat(1, order: 10)]
        repo.loadedChatListFolderId = 7

        try await repo.pinChat(chatId: 1, isPinned: true)
        XCTAssertEqual(service.pinnedChats.map(\.list), [.folder(7)])
        XCTAssertEqual(repo.chats.first?.isPinned, true, "pinned in the folder on screen")

        // Main says nothing about it: the folder's own pin is what the user changed.
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 10), positions: [ChatListPosition(list: .main, order: 10, isPinned: false)],
            source: .explicitPosition
        ))
        XCTAssertEqual(repo.chats.first?.isPinned, true)
        repo.handleChatPositionUpdate(.init(
            chat: chat(1, order: 10), positions: [ChatListPosition(list: .folder(7), order: 700, isPinned: true)],
            source: .explicitPosition
        ))
        XCTAssertEqual(repo.chats.first?.isPinned, true)
        XCTAssertEqual(repo.chats.first?.order, 700)
    }

    func testPinInMainTargetsMain() async throws {
        repo.chats = [chat(1, order: 10)]

        try await repo.pinChat(chatId: 1, isPinned: true)

        XCTAssertEqual(service.pinnedChats.map(\.list), [.main])
    }

    func testFailedPinInFolderRevertsOnlyThatFolder() async {
        repo.chats = [chat(1, order: 10)]
        // A pin asked for in Main is still waiting for TDLib's answer.
        _ = repo.store.setPendingPin(1, in: .main, to: true)
        repo.loadedChatListFolderId = 7
        service.pinChatError = TestError.failed("pinned chats limit")

        do {
            try await repo.pinChat(chatId: 1, isPinned: true)
            XCTFail("the service rejects the request")
        } catch {}

        XCTAssertEqual(repo.chats.first?.isPinned, false)
        XCTAssertEqual(repo.store.pendingPins, [.main: [1: true]], "only the folder's request failed")
        XCTAssertEqual(repo.store.chat(id: 1, stampedFor: .main)?.isPinned, true)
    }

    func testFailedMuteOfAnAlreadyMutedChatKeepsItMuted() async {
        var muted = chat(1, order: 10)
        muted.isMuted = true
        repo.chats = [muted]
        service.muteChatError = TestError.failed("offline")

        do {
            try await repo.muteChat(chatId: 1, isMuted: true)
            XCTFail("the service rejects the request")
        } catch {}

        XCTAssertEqual(repo.chats.first?.isMuted, true, "reverting means going back, not flipping")
    }

    // MARK: - Helpers

    private func makeRepository(service: TelegramServiceProtocol) -> ChatRepository {
        ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
    }

    private func chat(_ id: Int64, order: Int64) -> ChatInfo {
        ChatInfo(
            id: id, title: "Chat \(id)", lastMessage: nil, unreadCount: 0,
            isGroup: false, isMuted: false, order: order
        )
    }
}
