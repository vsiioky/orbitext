import XCTest
@testable import OrbitextWatch

/// MessageOrigin(tdApi:...) across all 4 variants + unknown.
final class UserMappingTests: XCTestCase {
    // MARK: - MessageOrigin from the generated type

    private func origin(
        _ dict: [String: Any],
        users: [Int64: String] = [:],
        chats: [Int64: String] = [:]
    ) -> MessageOrigin? {
        return MessageOrigin(
            tdApi: TDApi.decodeMessageOrigin(dict),
            resolveUserName: { users[$0] },
            resolveChatTitle: { chats[$0] }
        )
    }

    func testOriginUserResolvesNameFromClosure() {
        let result = origin(
            ["@type": "messageOriginUser", "sender_user_id": 7],
            users: [7: "Alice Smith"]
        )
        guard case .user(let userId, let name) = result else {
            return XCTFail("expected .user, got \(String(describing: result))")
        }
        XCTAssertEqual(userId, 7)
        XCTAssertEqual(name, "Alice Smith")
    }

    func testOriginUserFallsBackToMarkerWhenUnresolved() {
        let result = origin(["@type": "messageOriginUser", "sender_user_id": 42])
        guard case .user(let userId, let name) = result else {
            return XCTFail("expected .user")
        }
        XCTAssertEqual(userId, 42)
        XCTAssertEqual(name, "#user:42")
    }

    func testOriginHiddenUser() {
        let result = origin(["@type": "messageOriginHiddenUser", "sender_name": "Anon"])
        guard case .hiddenUser(let name) = result else {
            return XCTFail("expected .hiddenUser")
        }
        XCTAssertEqual(name, "Anon")
    }

    func testOriginChatWithSignature() {
        let result = origin(
            [
                "@type": "messageOriginChat",
                "sender_chat_id": 555,
                "author_signature": "Editor",
            ],
            chats: [555: "Group A"]
        )
        guard case .chat(let chatId, let title, let signature) = result else {
            return XCTFail("expected .chat")
        }
        XCTAssertEqual(chatId, 555)
        XCTAssertEqual(title, "Group A")
        XCTAssertEqual(signature, "Editor")
    }

    func testOriginChatEmptySignatureCollapsesToNil() {
        let result = origin([
            "@type": "messageOriginChat",
            "sender_chat_id": 1,
            "author_signature": "",
        ])
        guard case .chat(_, _, let signature) = result else {
            return XCTFail("expected .chat")
        }
        XCTAssertNil(signature)
    }

    func testOriginChannelUsesChatIdField() {
        let result = origin(
            ["@type": "messageOriginChannel", "chat_id": -1001, "author_signature": "Ed"],
            chats: [-1001: "News"]
        )
        guard case .channel(let chatId, let title, let signature) = result else {
            return XCTFail("expected .channel")
        }
        XCTAssertEqual(chatId, -1001)
        XCTAssertEqual(title, "News")
        XCTAssertEqual(signature, "Ed")
    }

    func testOriginUnknownTagReturnsNil() {
        XCTAssertNil(origin(["@type": "messageOriginFromMars"]))
    }

    func testOriginMissingTagReturnsNil() {
        XCTAssertNil(origin([:]))
    }

    // MARK: - Int64 coercion helper

    func testToInt64AcceptsStringInt64() {
        XCTAssertEqual(MessageOrigin.toInt64("9223372036854775000"), 9_223_372_036_854_775_000)
    }

    func testToInt64DefaultsToZero() {
        XCTAssertEqual(MessageOrigin.toInt64(nil), 0)
        XCTAssertEqual(MessageOrigin.toInt64("nope"), 0)
    }
}
