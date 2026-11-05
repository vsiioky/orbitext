import XCTest
@testable import OrbitextWatch

/// What the transport remembers about a user from updateUser, getUser, getMe
/// and updateUserStatus, seen through its consumers: contact cards, the
/// online flag of a private chat, the typing indicator and bot lookups. The
/// samples are TDLib 1.8.64 JSON (TDJSONSample); nothing reads the cache
/// itself, so the tests hold for any representation of it.
final class UserCacheBehaviorTests: XCTestCase {
    private typealias Sample = TDJSONSample

    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    private func nextEvent(timeout: TimeInterval = 1.0) async -> TDLibEvent? {
        await withTaskGroup(of: TDLibEvent?.self) { group in
            group.addTask { [events = service.events] in
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func privateChat(userId: Int64) -> [String: Any] {
        Sample.object("""
        {"@type":"chat","id":\(userId),"type":{"@type":"chatTypePrivate","user_id":\(userId)},\
        "title":"Someone","unread_count":0,"unread_mention_count":0,"unread_reaction_count":0,\
        "last_read_outbox_message_id":0,"positions":[]}
        """)
    }

    // MARK: - Contact card

    func testContactCardTakesTheNamesPhoneAndEditableUsername() {
        let user = Sample.object(Sample.user(
            id: 456,
            firstName: "John",
            lastName: "Doe",
            status: "{\"@type\":\"userStatusOnline\",\"expires\":1760000300}",
            usernames: """
            {"@type":"usernames","active_usernames":["johnny","jd"],"disabled_usernames":[],\
            "editable_username":"johnny","collectible_usernames":[]}
            """,
            phone: "15551234567"
        ))

        let contact = service.parseContactInfo(user)

        XCTAssertEqual(contact.id, 456)
        XCTAssertEqual(contact.firstName, "John")
        XCTAssertEqual(contact.lastName, "Doe")
        XCTAssertEqual(contact.phone, "15551234567")
        XCTAssertEqual(contact.username, "johnny")
        XCTAssertTrue(contact.isOnline)
        XCTAssertNil(contact.lastSeen)
        XCTAssertNil(contact.photoFileId)
    }

    func testContactCardOfAnOfflineUserHasTheLastSeenDate() {
        let user = Sample.object(Sample.user(
            id: 456,
            firstName: "John",
            status: "{\"@type\":\"userStatusOffline\",\"was_online\":1759990000}"
        ))

        let contact = service.parseContactInfo(user)

        XCTAssertFalse(contact.isOnline)
        XCTAssertEqual(contact.lastSeen, Date(timeIntervalSince1970: 1_759_990_000))
    }

    func testContactCardOfAUserSeenRecentlyHasNeitherFlagNorDate() {
        let user = Sample.object(Sample.user(
            id: 456,
            firstName: "John",
            status: "{\"@type\":\"userStatusRecently\",\"by_my_privacy_settings\":false}"
        ))

        let contact = service.parseContactInfo(user)

        XCTAssertFalse(contact.isOnline)
        XCTAssertNil(contact.lastSeen)
    }

    func testContactCardPhotoIsTheSmallProfilePhotoFile() {
        let user = Sample.object(Sample.user(id: 456, firstName: "John", profilePhotoSmallId: 9_081))

        XCTAssertEqual(service.parseContactInfo(user).photoFileId, "9081")
    }

    func testContactCardOfAUserWithoutNamesIsEmpty() {
        let user = Sample.object(Sample.user(id: 456, firstName: ""))

        let contact = service.parseContactInfo(user)

        XCTAssertEqual(contact.fullName, "")
        XCTAssertEqual(contact.username, "")
        XCTAssertEqual(contact.phone, "")
    }

    func testContactCardRemembersTheUserForLaterNameLookups() throws {
        _ = service.parseContactInfo(Sample.object(Sample.user(id: 1002, firstName: "Mia", lastName: "Me")))

        let message = try XCTUnwrap(service.parseMessageInfo(Sample.message(userId: 1002)))

        XCTAssertEqual(message.senderName, "Mia Me")
        XCTAssertTrue(message.senderResolved)
    }

    // MARK: - updateUser

    func testUpdateUserReplacesTheNameOfAKnownUser() throws {
        service.handleUpdate(Sample.updateUser(id: 1002, firstName: "Old", lastName: "Name"))
        service.handleUpdate(Sample.updateUser(id: 1002, firstName: "New", lastName: "Name"))

        let message = try XCTUnwrap(service.parseMessageInfo(Sample.message(userId: 1002)))

        XCTAssertEqual(message.senderName, "New Name")
    }

    func testUpdateUserNamesTheUserInReplyAndForwardOrigins() throws {
        service.handleUpdate(Sample.updateUser(id: 2001, firstName: "Origin", lastName: "User"))
        let members = Sample.replyToMessage(origin: Sample.originUser(2001))
            + Sample.forwardInfo(origin: Sample.originUser(2001))

        let message = try XCTUnwrap(service.parseMessageInfo(Sample.message(members: members)))

        XCTAssertEqual(message.replyToSenderName, "Origin User")
        XCTAssertEqual(message.forwardedOrigin, .user(userId: 2001, name: "Origin User"))
    }

    func testUpdateUserSetsTheOnlineFlagOfThePrivateChat() {
        service.handleUpdate(Sample.updateUser(
            id: 1002,
            firstName: "John",
            status: "{\"@type\":\"userStatusOnline\",\"expires\":1760000300}"
        ))

        XCTAssertTrue(service.parseChatInfo(privateChat(userId: 1002)).isOnline)
    }

    func testPrivateChatOfAnUnknownUserIsNotOnline() {
        XCTAssertFalse(service.parseChatInfo(privateChat(userId: 1002)).isOnline)
    }

    func testUpdateUserKeepsTheStoredChatInSyncWithTheStatus() async {
        service.chatCache.set(1002, service.parseChatInfo(privateChat(userId: 1002)))

        service.handleUpdate(Sample.updateUser(
            id: 1002,
            firstName: "John",
            status: "{\"@type\":\"userStatusOnline\",\"expires\":1760000300}"
        ))

        guard case .chatUpdated(let chat)? = await nextEvent() else {
            return XCTFail("expected .chatUpdated")
        }
        XCTAssertEqual(chat.id, 1002)
        XCTAssertTrue(chat.isOnline)
    }

    // MARK: - updateUserStatus

    func testUserStatusUpdateChangesWhatALaterChatParseSees() {
        service.handleUpdate(Sample.updateUser(
            id: 1002,
            firstName: "John",
            status: "{\"@type\":\"userStatusOnline\",\"expires\":1760000300}"
        ))
        XCTAssertTrue(service.parseChatInfo(privateChat(userId: 1002)).isOnline)

        service.handleUpdate(Sample.object("""
        {"@type":"updateUserStatus","user_id":1002,"status":{"@type":"userStatusOffline","was_online":1760000200}}
        """))

        XCTAssertFalse(service.parseChatInfo(privateChat(userId: 1002)).isOnline)
    }

    func testUserStatusUpdateKeepsTheNamesOfTheUser() throws {
        service.handleUpdate(Sample.updateUser(id: 1002, firstName: "John", lastName: "Doe"))

        service.handleUpdate(Sample.object("""
        {"@type":"updateUserStatus","user_id":1002,"status":{"@type":"userStatusOnline","expires":1760000300}}
        """))

        let message = try XCTUnwrap(service.parseMessageInfo(Sample.message(userId: 1002)))
        XCTAssertEqual(message.senderName, "John Doe")
    }

    func testUserStatusUpdateOfAnUnknownUserDoesNotRememberIt() throws {
        service.handleUpdate(Sample.object("""
        {"@type":"updateUserStatus","user_id":1002,"status":{"@type":"userStatusOnline","expires":1760000300}}
        """))

        let message = try XCTUnwrap(service.parseMessageInfo(Sample.message(userId: 1002)))
        XCTAssertFalse(message.senderResolved)
        XCTAssertFalse(service.parseChatInfo(privateChat(userId: 1002)).isOnline)
    }

    func testUserStatusUpdateEmitsTheOnlineFlagOfTheStoredChat() async {
        service.chatCache.set(1002, service.parseChatInfo(privateChat(userId: 1002)))

        service.handleUpdate(Sample.object("""
        {"@type":"updateUserStatus","user_id":1002,"status":{"@type":"userStatusOnline","expires":1760000300}}
        """))

        guard case .chatUpdated(let chat)? = await nextEvent() else {
            return XCTFail("expected .chatUpdated")
        }
        XCTAssertTrue(chat.isOnline)
    }

    // MARK: - Typing indicator

    private func typingUpdate(userId: Int64) -> [String: Any] {
        Sample.object("""
        {"@type":"updateChatAction","chat_id":-1001234567890,"sender_id":{"@type":"messageSenderUser","user_id":\(userId)},\
        "action":{"@type":"chatActionTyping"}}
        """)
    }

    func testTypingIndicatorUsesTheFirstNameOfAKnownUser() async {
        service.handleUpdate(Sample.updateUser(id: 1002, firstName: "John", lastName: "Doe"))

        service.handleUpdate(typingUpdate(userId: 1002))

        guard case .chatAction(_, let names, let kind)? = await nextEvent() else {
            return XCTFail("expected .chatAction")
        }
        XCTAssertEqual(names, ["John"])
        XCTAssertEqual(kind, .typing)
    }

    func testTypingIndicatorNamesAnUnknownUserSomeone() async {
        service.handleUpdate(typingUpdate(userId: 1002))

        guard case .chatAction(_, let names, _)? = await nextEvent() else {
            return XCTFail("expected .chatAction")
        }
        XCTAssertEqual(names, ["Someone"])
    }
}
