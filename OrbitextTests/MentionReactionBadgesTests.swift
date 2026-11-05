import XCTest
@testable import OrbitextWatch

@MainActor
final class MentionReactionBadgesTests: XCTestCase {
    private var service: MockTelegramService!
    private var repo: ChatRepository!

    override func setUp() async throws {
        service = MockTelegramService()
        repo = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repo.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 10)
        ]
    }

    override func tearDown() async throws {
        repo?.chatListCache.clear()
        repo = nil
        service = nil
    }

    // MARK: - badgeKind priority

    func testBadgeKindIsNoneWhenAllCountsZero() {
        let chat = ChatInfo(id: 1, title: "A", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        XCTAssertEqual(chat.badgeKind, .none)
    }

    func testBadgeKindMessageWhenOnlyUnread() {
        let chat = ChatInfo(id: 1, title: "A", lastMessage: nil, unreadCount: 5, isGroup: false, isMuted: false, order: 1)
        XCTAssertEqual(chat.badgeKind, .message(5))
    }

    func testReactionBeatsMessage() {
        var chat = ChatInfo(id: 1, title: "A", lastMessage: nil, unreadCount: 5, isGroup: false, isMuted: false, order: 1)
        chat.reactionCount = 1
        XCTAssertEqual(chat.badgeKind, .reaction)
    }

    func testMentionBeatsReactionAndMessage() {
        var chat = ChatInfo(id: 1, title: "A", lastMessage: nil, unreadCount: 5, isGroup: false, isMuted: false, order: 1)
        chat.reactionCount = 2
        chat.mentionCount = 1
        XCTAssertEqual(chat.badgeKind, .mention)
    }

    // MARK: - repository mutation

    func testSetMentionCountUpdatesChat() {
        repo.setMentionCount(chatId: 1, count: 3)
        XCTAssertEqual(repo.chats.first?.mentionCount, 3)
        XCTAssertEqual(repo.chats.first?.badgeKind, .mention)
    }

    func testSetReactionCountUpdatesChat() {
        repo.setReactionCount(chatId: 1, count: 2)
        XCTAssertEqual(repo.chats.first?.reactionCount, 2)
        XCTAssertEqual(repo.chats.first?.badgeKind, .reaction)
    }

    func testResettingMentionCountToZeroFallsBackToNextKind() {
        repo.setMentionCount(chatId: 1, count: 4)
        repo.setReactionCount(chatId: 1, count: 1)
        XCTAssertEqual(repo.chats.first?.badgeKind, .mention)

        repo.setMentionCount(chatId: 1, count: 0)
        XCTAssertEqual(repo.chats.first?.badgeKind, .reaction)

        repo.setReactionCount(chatId: 1, count: 0)
        XCTAssertEqual(repo.chats.first?.badgeKind, ChatBadgeKind.none)
    }

    func testSetMentionCountOnUnknownChatIsNoop() {
        repo.setMentionCount(chatId: 9999, count: 5)
        XCTAssertEqual(repo.chats.first?.mentionCount, 0)
    }
}
