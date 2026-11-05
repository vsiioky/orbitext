import XCTest
@testable import OrbitextWatch

@MainActor
final class MessageActionsTests: XCTestCase {
    private var service: MockTelegramService!
    private var store: ChatMessageStore!

    override func setUp() async throws {
        service = MockTelegramService()
        let messageManager = MessageManager(service: service, messageQueue: MessageQueue())
        let chatRepository = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        store = ChatMessageStore(messageManager: messageManager, chatRepository: chatRepository)
    }

    // MARK: - Parser

    func testParseMessagePropertiesReadsAllBoolFlags() {
        let svc = TDLibService.testInstance()
        let raw: [String: Any] = [
            "@type": "messageProperties",
            "can_be_edited": true,
            "can_be_deleted_only_for_self": true,
            "can_be_deleted_for_all_users": false,
            "can_be_forwarded": true,
            "can_be_replied": true,
            "can_be_saved": false,
            "can_be_pinned": true
        ]
        let props = svc.parseMessageProperties(from: raw)
        XCTAssertTrue(props.isResolved)
        XCTAssertTrue(props.canBeEdited)
        XCTAssertTrue(props.canBeDeletedOnlyForSelf)
        XCTAssertFalse(props.canBeDeletedForAllUsers)
        XCTAssertTrue(props.canBeForwarded)
        XCTAssertTrue(props.canBeReplied)
        XCTAssertFalse(props.canBeSaved)
        XCTAssertTrue(props.canBePinned)
    }

    func testParseMessagePropertiesMissingFieldsFallBackToFalse() {
        let svc = TDLibService.testInstance()
        let props = svc.parseMessageProperties(from: ["@type": "messageProperties"])
        XCTAssertTrue(props.isResolved)
        XCTAssertFalse(props.canBeEdited)
        XCTAssertFalse(props.canBeForwarded)
        XCTAssertFalse(props.canBeReplied)
        XCTAssertFalse(props.canBeSaved)
    }

    // MARK: - Cache

    func testFetchMessagePropertiesCachesResult() async {
        var fixture = MessageProperties.default
        fixture.canBeEdited = true
        fixture.isResolved = true
        service.messagePropertiesByMessage[42] = fixture

        XCTAssertNil(store.cachedProperties(chatId: 1, messageId: 42))

        let fetched = await store.fetchMessageProperties(chatId: 1, messageId: 42)
        XCTAssertTrue(fetched.canBeEdited)
        XCTAssertEqual(store.cachedProperties(chatId: 1, messageId: 42), fixture)
        XCTAssertEqual(service.getMessagePropertiesCalls.count, 1)

        // Second call must hit the cache (no extra TDLib round-trip).
        let again = await store.fetchMessageProperties(chatId: 1, messageId: 42)
        XCTAssertEqual(again, fixture)
        XCTAssertEqual(service.getMessagePropertiesCalls.count, 1)
    }

    func testInvalidateMessagePropertiesDropsCachedEntry() async {
        var fixture = MessageProperties.default
        fixture.canBeEdited = true
        fixture.isResolved = true
        service.messagePropertiesByMessage[7] = fixture

        _ = await store.fetchMessageProperties(chatId: 5, messageId: 7)
        XCTAssertNotNil(store.cachedProperties(chatId: 5, messageId: 7))

        store.invalidateMessageProperties(chatId: 5, messageId: 7)
        XCTAssertNil(store.cachedProperties(chatId: 5, messageId: 7))

        // Next call refetches: prove via the call counter.
        _ = await store.fetchMessageProperties(chatId: 5, messageId: 7)
        XCTAssertEqual(service.getMessagePropertiesCalls.count, 2)
    }

    func testFetchMessagePropertiesFailureReturnsDefaultWithoutCaching() async {
        service.getMessagePropertiesError = TDError.unexpectedResponse

        let fetched = await store.fetchMessageProperties(chatId: 9, messageId: 1)
        XCTAssertEqual(fetched, MessageProperties.default)
        XCTAssertNil(store.cachedProperties(chatId: 9, messageId: 1))
    }

    // MARK: - Fallback heuristic

    func testIsEditableFallsBackToClientHeuristicWhenUnresolved() {
        let outgoingText = MessageInfo(id: 1, chatId: 1, senderName: "Me", senderId: 1, content: .text("hi"), date: Date(), isOutgoing: true, isRead: true)
        XCTAssertTrue(outgoingText.isEditable)

        let incomingText = MessageInfo(id: 2, chatId: 1, senderName: "Alice", senderId: 2, content: .text("hi"), date: Date(), isOutgoing: false, isRead: false)
        XCTAssertFalse(incomingText.isEditable)
    }

    func testIsEditableHonoursResolvedServerFlag() {
        var props = MessageProperties.default
        props.isResolved = true
        props.canBeEdited = false // server says no even though heuristic would say yes
        var msg = MessageInfo(id: 1, chatId: 1, senderName: "Me", senderId: 1, content: .text("hi"), date: Date(), isOutgoing: true, isRead: true)
        msg.properties = props
        XCTAssertFalse(msg.isEditable)
    }
}

// MARK: - TDLibService instantiation helper for unit tests

private extension TDLibService {
    static func testInstance() -> TDLibService {
        TDLibService()
    }
}
