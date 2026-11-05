import XCTest
@testable import OrbitextWatch

/// A position in another chat list is not a position in Main. These events
/// used to be dropped by the transport; they now reach the repository, which
/// must keep them out of the list on screen. The one exception is the archive
/// taking a chat: Main and the archive exclude each other.
@MainActor
final class ChatListIsolationTests: XCTestCase {
    private var repo: ChatRepository!

    override func setUp() async throws {
        ListCache<ChatInfo>(filename: "cached_chats.json").clear()
        repo = ChatRepository(
            service: MockTelegramService(),
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
    }

    override func tearDown() async throws {
        repo?.chatListCache.clear()
        repo = nil
    }

    func testFolderAndArchivePositionEventsDoNotChangeTheMainList() {
        let rows = [chat(1, order: 30, pinned: true), chat(2, order: 20), chat(3, order: 10)]
        repo.chats = rows
        repo.saveChatsToCache()
        repo.chatListCache.flush()

        let ordersByList: [(list: ChatListID, orders: [Int64])] = [(.folder(7), [0, 5]), (.archive, [0])]
        for (list, orders) in ordersByList {
            for order in orders {
                repo.handleChatPositionUpdate(.init(
                    chat: rows[0],
                    positions: [ChatListPosition(list: list, order: order, isPinned: order > 0)],
                    source: .explicitPosition
                ))
            }
        }

        XCTAssertEqual(repo.chats.map(\.id), [1, 2, 3])
        XCTAssertEqual(repo.chats.map(\.order), [30, 20, 10])
        XCTAssertEqual(repo.chats.map(\.isPinned), [true, false, false])
        repo.chatListCache.flush()
        XCTAssertEqual(repo.chatListCache.load()?.map(\.id), [1, 2, 3])
    }

    func testArchivePositionTakesTheChatOutOfMain() {
        let rows = [chat(1, order: 30, pinned: true), chat(2, order: 20)]
        repo.chats = rows

        repo.handleChatPositionUpdate(.init(
            chat: rows[0],
            positions: [ChatListPosition(list: .archive, order: 5, isPinned: false)],
            source: .explicitPosition
        ))

        XCTAssertEqual(repo.chats.map(\.id), [2])
        XCTAssertEqual(repo.store.chats(in: .archive).map(\.id), [1])
    }

    func testNewChatAnnouncementWithoutMainPositionDoesNotRemoveMainRows() {
        let rows = [chat(1, order: 30), chat(2, order: 20)]
        repo.chats = rows

        repo.handleChatPositionUpdate(.init(
            chat: rows[0],
            positions: [ChatListPosition(list: .folder(7), order: 4, isPinned: false)],
            source: .newChat
        ))
        repo.handleChatPositionUpdate(.init(chat: rows[1], positions: [], source: .newChat))

        XCTAssertEqual(repo.chats.map(\.id), [1, 2])
        XCTAssertEqual(repo.chats.map(\.order), [30, 20])
    }

    private func chat(_ id: Int64, order: Int64, pinned: Bool = false) -> ChatInfo {
        ChatInfo(
            id: id, title: "Chat \(id)", lastMessage: nil, unreadCount: 0,
            isGroup: false, isMuted: false, order: order, isPinned: pinned
        )
    }
}
