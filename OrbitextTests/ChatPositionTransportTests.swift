import XCTest
@testable import OrbitextWatch

/// What the transport reports about a chat's place in each chat list. The
/// mirror (`chatCache`) stays Main-only; the events carry every list.
final class ChatPositionTransportTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - updateChatPosition

    func testFolderPositionIsReportedWithItsList() async {
        seedMirror(chatId: 302, mainOrder: 50)

        service.handleUpdate(positionUpdate(chatId: 302, list: folderList(7), order: 1, isPinned: true))

        let updates = await positionUpdates()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.source, .explicitPosition)
        XCTAssertEqual(updates.first?.positions, [ChatListPosition(list: .folder(7), order: 1, isPinned: true)])
        XCTAssertEqual(service.chatCache.get(302)?.order, 50, "the mirror keeps the Main values")
        XCTAssertEqual(service.chatCache.get(302)?.isPinned, false)
    }

    func testArchivePositionIsReported() async {
        seedMirror(chatId: 303, mainOrder: 50)

        service.handleUpdate(positionUpdate(chatId: 303, list: ["@type": "chatListArchive"], order: 9, isPinned: false))

        let updates = await positionUpdates()
        XCTAssertEqual(updates.first?.positions, [ChatListPosition(list: .archive, order: 9, isPinned: false)])
        XCTAssertEqual(updates.first?.source, .explicitPosition)
    }

    func testMainPositionStillUpdatesTheMirror() async {
        seedMirror(chatId: 304, mainOrder: 50)

        service.handleUpdate(positionUpdate(chatId: 304, list: mainList, order: 70, isPinned: true))

        let updates = await positionUpdates()
        XCTAssertEqual(updates.first?.positions, [ChatListPosition(list: .main, order: 70, isPinned: true)])
        XCTAssertEqual(updates.first?.chat.order, 70)
        XCTAssertEqual(service.chatCache.get(304)?.order, 70)
        XCTAssertEqual(service.chatCache.get(304)?.isPinned, true)
    }

    func testOrderSentAsStringIsParsed() async {
        seedMirror(chatId: 305, mainOrder: 50)

        // TDLib sends int64 as a JSON string.
        service.handleUpdate(positionUpdate(chatId: 305, list: folderList(7), order: "9223372036854775000", isPinned: false))

        let updates = await positionUpdates()
        XCTAssertEqual(updates.first?.positions.first?.order, 9_223_372_036_854_775_000)
    }

    func testUnknownChatListIsDropped() async {
        seedMirror(chatId: 306, mainOrder: 50)

        service.handleUpdate(positionUpdate(chatId: 306, list: ["@type": "chatListFromTheFuture"], order: 4, isPinned: false))

        let events = await drainEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testPositionOfAChatTheMirrorDoesNotKnowIsNotReported() async {
        service.handleUpdate(positionUpdate(chatId: 307, list: folderList(7), order: 3, isPinned: false))

        let events = await drainEvents()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - updateChatLastMessage / updateChatDraftMessage

    func testLastMessagePositionsVectorIsReportedWhole() async {
        await assertVectorIsReportedWhole(type: "updateChatLastMessage")
    }

    func testDraftMessagePositionsVectorIsReportedWhole() async {
        await assertVectorIsReportedWhole(type: "updateChatDraftMessage")
    }

    private func assertVectorIsReportedWhole(type: String, file: StaticString = #filePath, line: UInt = #line) async {
        seedMirror(chatId: 310, mainOrder: 50)
        seedMirror(chatId: 311, mainOrder: 50)
        seedMirror(chatId: 312, mainOrder: 50)

        service.handleUpdate([
            "@type": type, "chat_id": 310,
            "positions": [
                position(list: mainList, order: 80, isPinned: true),
                position(list: folderList(7), order: 3, isPinned: false)
            ]
        ])
        service.handleUpdate(["@type": type, "chat_id": 311, "positions": [] as [[String: Any]]])
        service.handleUpdate(["@type": type, "chat_id": 312])

        let events = await drainEvents()
        guard events.count == 3,
              case .chatPositionChanged(let both) = events[0],
              case .chatPositionChanged(let none) = events[1],
              case .chatUpdated(let untouched) = events[2] else {
            return XCTFail("unexpected events \(events)", file: file, line: line)
        }
        XCTAssertEqual(both.source, .positionsReplacement, file: file, line: line)
        XCTAssertEqual(both.positions, [
            ChatListPosition(list: .main, order: 80, isPinned: true),
            ChatListPosition(list: .folder(7), order: 3, isPinned: false)
        ], file: file, line: line)
        XCTAssertEqual(both.chat.order, 80, "the mirror follows the Main entry of the vector", file: file, line: line)
        XCTAssertEqual(none.source, .positionsReplacement, file: file, line: line)
        XCTAssertEqual(none.positions, [], file: file, line: line)
        XCTAssertEqual(none.chat.order, 0, file: file, line: line)
        XCTAssertEqual(untouched.id, 312, file: file, line: line)
        XCTAssertEqual(untouched.order, 50, "a vector that is absent changes no position", file: file, line: line)
    }

    // MARK: - updateNewChat

    func testNewChatIsReportedWithEveryListAndWithoutPositions() async {
        service.handleUpdate(newChatUpdate(id: 320, positions: [
            position(list: mainList, order: 40, isPinned: false),
            position(list: folderList(7), order: 5, isPinned: true),
            position(list: ["@type": "chatListArchive"], order: 6, isPinned: false)
        ]))
        service.handleUpdate(newChatUpdate(id: 321, positions: []))
        service.handleUpdate(newChatUpdate(id: 322, positions: nil))

        let events = await drainEvents()
        let updates = events.compactMap { event -> ChatPositionUpdate? in
            if case .chatPositionChanged(let update) = event { return update }
            return nil
        }
        XCTAssertEqual(updates.map(\.chat.id), [320, 321, 322])
        XCTAssertTrue(updates.allSatisfy { $0.source == .newChat })
        XCTAssertEqual(updates[0].positions, [
            ChatListPosition(list: .main, order: 40, isPinned: false),
            ChatListPosition(list: .folder(7), order: 5, isPinned: true),
            ChatListPosition(list: .archive, order: 6, isPinned: false)
        ])
        XCTAssertEqual(updates[0].chat.order, 40)
        XCTAssertEqual(updates[1].positions, [], "a chat nobody listed is still announced")
        XCTAssertEqual(updates[2].positions, [])
        XCTAssertNotNil(service.chatCache.get(322))
    }

    func testNewChatWithoutAnIdIsIgnored() async {
        service.handleUpdate(["@type": "updateNewChat", "chat": ["title": "No id"] as [String: Any]])

        let events = await drainEvents()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - getChat against the mirror

    func testGetChatKeepsWhatUpdatesBroughtWhileItWasInFlight() async throws {
        let fixture = ScriptedServiceFixture { request in
            request["@type"] as? String == "getChat"
                ? .delayed(0.25, Self.chatAnswer(id: 77))
                : .error(code: 400, message: "Unexpected request")
        }
        defer { fixture.finish() }
        async let fetched = fixture.service.getChat(chatId: 77)
        while !fixture.transport.methods.contains("getChat") { await Task.yield() }

        // The answer predates these: TDLib announced the chat, pinned it and
        // muted it after it computed the answer, which has no positions.
        fixture.service.handleUpdate(newChatUpdate(id: 77, positions: [
            position(list: mainList, order: 500, isPinned: true)
        ]))
        fixture.service.handleUpdate([
            "@type": "updateChatNotificationSettings", "chat_id": 77,
            "notification_settings": ["@type": "chatNotificationSettings", "mute_for": 3600] as [String: Any]
        ])
        let chat = try await fetched

        XCTAssertEqual(chat.order, 500)
        XCTAssertEqual(chat.isPinned, true, "order and pin are one position and stay together")
        XCTAssertEqual(chat.isMuted, true, "the mute is newer than the answer")
        XCTAssertEqual(fixture.service.chatCache.get(77), chat, "the mirror was not rolled back")
    }

    func testGetChatFillsTheMirrorWhenNothingAnnouncedTheChat() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.chatAnswer(id: 78)) }
        defer { fixture.finish() }

        let chat = try await fixture.service.getChat(chatId: 78)

        XCTAssertEqual(chat.title, "Answer 78")
        XCTAssertEqual(fixture.service.chatCache.get(78), chat)
    }

    // MARK: - Requests

    func testPinRequestNamesItsChatList() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        try await fixture.service.pinChat(chatId: 5, in: .folder(7), isPinned: true)
        try await fixture.service.pinChat(chatId: 5, in: .main, isPinned: false)
        try await fixture.service.pinChat(chatId: 6, isPinned: true)

        let requests = fixture.transport.requests(ofType: "toggleChatIsPinned")
        XCTAssertEqual(requests.count, 3)
        let lists = requests.map { $0["chat_list"] as? [String: Any] }
        XCTAssertEqual(lists[0]?["@type"] as? String, "chatListFolder")
        XCTAssertEqual(lists[0]?["chat_folder_id"] as? Int, 7)
        XCTAssertEqual(lists[1]?["@type"] as? String, "chatListMain")
        XCTAssertEqual(lists[2]?["@type"] as? String, "chatListMain", "the old entry point is Main")
        XCTAssertEqual(requests.map { $0["is_pinned"] as? Bool }, [true, false, true])
        XCTAssertEqual(requests.map { $0["chat_id"] as? Int }, [5, 5, 6])
    }

    // MARK: - Helpers

    private let mainList: [String: Any] = ["@type": "chatListMain"]

    private func folderList(_ id: Int) -> [String: Any] {
        ["@type": "chatListFolder", "chat_folder_id": id]
    }

    private func position(list: [String: Any], order: Any, isPinned: Bool) -> [String: Any] {
        ["@type": "chatPosition", "list": list, "order": order, "is_pinned": isPinned]
    }

    private func positionUpdate(chatId: Int, list: [String: Any], order: Any, isPinned: Bool) -> [String: Any] {
        ["@type": "updateChatPosition", "chat_id": chatId, "position": position(list: list, order: order, isPinned: isPinned)]
    }

    private func newChatUpdate(id: Int, positions: [[String: Any]]?) -> [String: Any] {
        var chat: [String: Any] = [
            "@type": "chat", "id": id, "title": "Chat \(id)",
            "type": ["@type": "chatTypePrivate", "user_id": id] as [String: Any]
        ]
        if let positions { chat["positions"] = positions }
        return ["@type": "updateNewChat", "chat": chat]
    }

    private static func chatAnswer(id: Int) -> [String: Any] {
        [
            "@type": "chat", "id": id, "title": "Answer \(id)",
            "type": ["@type": "chatTypePrivate", "user_id": id] as [String: Any],
            "positions": [Any](),
            "notification_settings": ["@type": "chatNotificationSettings", "mute_for": 0] as [String: Any]
        ]
    }

    private func seedMirror(chatId: Int64, mainOrder: Int64) {
        service.chatCache.set(
            chatId,
            ChatInfo(id: chatId, title: "Stable", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: mainOrder)
        )
    }

    private func drainEvents() async -> [TDLibEvent] {
        service.session.finishEventsForTesting()
        var events: [TDLibEvent] = []
        for await event in service.events { events.append(event) }
        return events
    }

    private func positionUpdates() async -> [ChatPositionUpdate] {
        await drainEvents().compactMap { event in
            if case .chatPositionChanged(let update) = event { return update }
            return nil
        }
    }
}
