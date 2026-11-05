import XCTest
@testable import OrbitextWatch

final class MessageOriginTests: XCTestCase {
    private var service: TDLibService!

    private func origin(_ raw: [String: Any]) -> MessageOrigin? {
        service.messageOrigin(from: TDApi.decodeMessageOrigin(raw))
    }

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - displayName

    func testDisplayNameForUser() {
        let origin = MessageOrigin.user(userId: 42, name: "Alice")
        XCTAssertEqual(origin.displayName, "Alice")
        XCTAssertFalse(origin.isChannel)
    }

    func testDisplayNameForHiddenUser() {
        let origin = MessageOrigin.hiddenUser(name: "Anonymous")
        XCTAssertEqual(origin.displayName, "Anonymous")
        XCTAssertFalse(origin.isChannel)
    }

    func testDisplayNameForChatWithSignature() {
        let origin = MessageOrigin.chat(chatId: 7, title: "Group", authorSignature: "Bob")
        XCTAssertEqual(origin.displayName, "Group (Bob)")
        XCTAssertFalse(origin.isChannel)
    }

    func testDisplayNameForChatWithoutSignature() {
        let origin = MessageOrigin.chat(chatId: 7, title: "Group", authorSignature: nil)
        XCTAssertEqual(origin.displayName, "Group")
    }

    func testDisplayNameForChatWithEmptySignature() {
        let origin = MessageOrigin.chat(chatId: 7, title: "Group", authorSignature: "")
        XCTAssertEqual(origin.displayName, "Group")
    }

    func testDisplayNameForChannel() {
        let origin = MessageOrigin.channel(chatId: 9, title: "News", authorSignature: "Editor")
        XCTAssertEqual(origin.displayName, "News (Editor)")
        XCTAssertTrue(origin.isChannel)
    }

    // MARK: - messageOrigin(from:)

    func testParseMessageOriginUserUsesUserCacheWhenAvailable() {
        service.userCache.set(123, .sample(id: 123, firstName: "John", lastName: "Doe"))
        let raw: [String: Any] = [
            "@type": "messageOriginUser",
            "sender_user_id": 123
        ]
        let origin = self.origin(raw)
        guard case .user(let userId, let name) = origin else {
            return XCTFail("expected user")
        }
        XCTAssertEqual(userId, 123)
        XCTAssertEqual(name, "John Doe")
    }

    func testParseMessageOriginUserFallsBackToMarker() {
        let raw: [String: Any] = [
            "@type": "messageOriginUser",
            "sender_user_id": 555
        ]
        let origin = self.origin(raw)
        guard case .user(let userId, let name) = origin else {
            return XCTFail("expected user")
        }
        XCTAssertEqual(userId, 555)
        XCTAssertEqual(name, "#user:555") // resolved later by resolveMessageNames
    }

    func testParseMessageOriginHiddenUser() {
        let raw: [String: Any] = [
            "@type": "messageOriginHiddenUser",
            "sender_name": "Anon"
        ]
        guard case .hiddenUser(let name) = origin(raw) else {
            return XCTFail("expected hiddenUser")
        }
        XCTAssertEqual(name, "Anon")
    }

    func testParseMessageOriginChannel() {
        service.chatCache.set(
            -1001,
            ChatInfo(id: -1001, title: "Daily News", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
        )
        let raw: [String: Any] = [
            "@type": "messageOriginChannel",
            "chat_id": -1001,
            "author_signature": "Editor"
        ]
        guard case .channel(let chatId, let title, let sig) = origin(raw) else {
            return XCTFail("expected channel")
        }
        XCTAssertEqual(chatId, -1001)
        XCTAssertEqual(title, "Daily News")
        XCTAssertEqual(sig, "Editor")
    }

    func testParseMessageOriginUnknownReturnsNil() {
        XCTAssertNil(origin(["@type": "messageOriginNebula"]))
    }

    // MARK: - Integration: parseMessageInfo populates forwardedOrigin

    func testParseMessageInfoSetsForwardedOriginForChannel() {
        service.chatCache.set(
            -2002,
            ChatInfo(id: -2002, title: "Tech Channel", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
        )
        let dict: [String: Any] = [
            "id": 1,
            "chat_id": 99,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "fwd"] as [String: Any]] as [String: Any],
            "forward_info": [
                "origin": [
                    "@type": "messageOriginChannel",
                    "chat_id": -2002,
                    "author_signature": ""
                ] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = service.parseMessageInfo(dict)
        XCTAssertNotNil(parsed?.forwardedOrigin)
        XCTAssertTrue(parsed?.forwardedOrigin?.isChannel ?? false)
        XCTAssertEqual(parsed?.forwardedOrigin?.displayName, "Tech Channel")
        XCTAssertEqual(parsed?.forwardedFrom, "Tech Channel")
    }
}
