import XCTest
@testable import OrbitextWatch

/// resolveMessageNames for replies whose original is not on the page: the
/// service fetches the replied message with getMessage (and its sender with
/// getUser) from a scripted TDLib and fills in the sender name and preview.
/// Messages and users are TDLib 1.8.64 JSON (TDJSONSample).
final class ReplyNameResolutionTests: XCTestCase {
    private typealias Sample = TDJSONSample

    private static let repliedId: Int64 = 3_141_592
    private static let chatSenderId: Int64 = -1_002_233_445_566

    private func fixture(
        replied: @escaping @Sendable () -> String?,
        users: [Int64: String] = [:]
    ) -> ScriptedServiceFixture {
        ScriptedServiceFixture { request in
            switch request["@type"] as? String {
            case "getMessage":
                guard let json = replied() else { return .error(code: 404, message: "Message not found") }
                return .result(Sample.object(json))
            case "getUser":
                let userId = request["user_id"] as? Int64 ?? Int64(request["user_id"] as? Int ?? 0)
                guard let json = users[userId] else { return .error(code: 404, message: "User not found") }
                return .result(Sample.object(json))
            default:
                return .result(["@type": "ok"])
            }
        }
    }

    /// The message TDLib returns for the reply target, sent by `userId`.
    private static func repliedMessage(userId: Int64 = 3001, content: String = Sample.textContent) -> String {
        messageJSON(sender: "{\"@type\":\"messageSenderUser\",\"user_id\":\(userId)}", content: content)
    }

    private static func messageJSON(sender: String, content: String) -> String {
        """
        {"@type":"message","id":\(repliedId),"sender_id":\(sender),"chat_id":-1001234567890,\
        "is_outgoing":false,"date":1759990000,"content":\(content)}
        """
    }

    private static func text(_ text: String, entities: String = "") -> String {
        """
        {"@type":"messageText","text":{"@type":"formattedText","text":"\(text)","entities":[\(entities)]}}
        """
    }

    /// A reply to `repliedId` whose sender and preview are still unknown.
    private func unresolvedReply(_ service: TDLibService, members: String? = nil) throws -> MessageInfo {
        try XCTUnwrap(service.parseMessageInfo(Sample.message(
            id: 3_145_800,
            members: members ?? Sample.replyToMessage(messageId: Self.repliedId)
        )))
    }

    private func resolve(_ service: TDLibService, _ message: MessageInfo) async -> MessageInfo {
        var messages = [message]
        await service.resolveMessageNames(&messages)
        return messages[0]
    }

    // MARK: - Sender

    func testSenderAndPreviewComeFromTheRepliedMessage() async throws {
        let alice = Sample.user(id: 3001, firstName: "Alice", lastName: "Original")
        let fixture = fixture(replied: { Self.repliedMessage(content: Self.text("Original text")) }, users: [3001: alice])
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToSenderName, "Alice Original")
        XCTAssertTrue(resolved.replyToSenderResolved)
        XCTAssertEqual(resolved.replyToPreview?.text, "Original text")
        XCTAssertEqual(fixture.transport.requests(ofType: "getMessage").count, 1)
    }

    func testSenderStaysAPlaceholderWhenTheUserCannotBeLoaded() async throws {
        let fixture = fixture(replied: { Self.repliedMessage(content: Self.text("Original text")) })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToSenderName, L10n.string("User"))
        XCTAssertFalse(resolved.replyToSenderResolved)
        XCTAssertEqual(resolved.replyToPreview?.text, "Original text")
    }

    func testSenderIsTheChatTitleWhenTheRepliedMessageCameFromAChat() async throws {
        let fixture = fixture(replied: {
            Self.messageJSON(
                sender: "{\"@type\":\"messageSenderChat\",\"chat_id\":\(Self.chatSenderId)}",
                content: Self.text("From the channel")
            )
        })
        defer { fixture.finish() }
        fixture.service.chatCache.set(
            Self.chatSenderId,
            ChatInfo(id: Self.chatSenderId, title: "Tech Channel", lastMessage: nil, unreadCount: 0,
                     isGroup: false, isMuted: false, order: 0)
        )

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToSenderName, "Tech Channel")
        XCTAssertTrue(resolved.replyToSenderResolved)
    }

    func testChatSenderThatIsNotKnownIsNamedChat() async throws {
        let fixture = fixture(replied: {
            Self.messageJSON(
                sender: "{\"@type\":\"messageSenderChat\",\"chat_id\":\(Self.chatSenderId)}",
                content: Self.text("From a channel")
            )
        })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToSenderName, L10n.string("Chat"))
        XCTAssertTrue(resolved.replyToSenderResolved)
    }

    func testRepliedMessageThatCannotBeFetchedLeavesTheReplyUnresolved() async throws {
        let fixture = fixture(replied: { nil })
        defer { fixture.finish() }
        let reply = try unresolvedReply(fixture.service)

        let resolved = await resolve(fixture.service, reply)

        XCTAssertEqual(resolved, reply)
        XCTAssertFalse(resolved.replyToSenderResolved)
        XCTAssertNil(resolved.replyToPreview)
    }

    // MARK: - Preview

    func testPreviewOfARepliedPollNamesTheQuestion() async throws {
        let fixture = fixture(replied: { Self.repliedMessage(content: Sample.poll(question: "Lunch?")) })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToPreview?.text, "📊 Lunch?")
    }

    func testPreviewOfARepliedPhotoWithoutACaptionNamesTheKind() async throws {
        let photo = """
        {"@type":"messagePhoto","photo":{"@type":"photo","has_stickers":false,"sizes":[\
        {"@type":"photoSize","type":"x","photo":{"@type":"file","id":42,"size":1000,"expected_size":1000},\
        "width":320,"height":240,"progressive_sizes":[]}]},\
        "caption":{"@type":"formattedText","text":"","entities":[]},"show_caption_above_media":false,\
        "has_spoiler":false,"is_secret":false}
        """
        let fixture = fixture(replied: { Self.repliedMessage(content: photo) })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToPreview?.text, L10n.string("Photo"))
    }

    func testPreviewMasksSpoilersOfTheRepliedText() async throws {
        let spoiler = Sample.entity(offset: 6, length: 4, type: "textEntityTypeSpoiler")
        let fixture = fixture(replied: { Self.repliedMessage(content: Self.text("Code: 1234", entities: spoiler)) })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToPreview?.text, "Code: ▒▒▒▒")
    }

    func testPreviewOfContentTheMappingDoesNotKnowIsTheKind() async throws {
        let dice = "{\"@type\":\"messageDice\",\"emoji\":\"🎲\",\"value\":4}"
        let fixture = fixture(replied: { Self.repliedMessage(content: dice) })
        defer { fixture.finish() }

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToPreview?.text, MessageContent.unsupported("Dice").textPreview)
    }

    func testReplyWithAKnownSenderStillFetchesAMissingPreview() async throws {
        let fixture = fixture(replied: { Self.repliedMessage(content: Self.text("Original text")) })
        defer { fixture.finish() }
        fixture.service.handleUpdate(Sample.updateUser(id: 2001, firstName: "Known", lastName: "Author"))
        let reply = try unresolvedReply(
            fixture.service,
            members: Sample.replyToMessage(messageId: Self.repliedId, origin: Sample.originUser(2001))
        )
        XCTAssertTrue(reply.replyToSenderResolved)

        let resolved = await resolve(fixture.service, reply)

        XCTAssertEqual(resolved.replyToSenderName, "Known Author")
        XCTAssertEqual(resolved.replyToPreview?.text, "Original text")
    }

    func testReplyWithQuoteAndKnownSenderFetchesNothing() async throws {
        let fixture = fixture(replied: { Self.repliedMessage() })
        defer { fixture.finish() }
        fixture.service.handleUpdate(Sample.updateUser(id: 2001, firstName: "Known", lastName: "Author"))
        let reply = try unresolvedReply(
            fixture.service,
            members: Sample.replyToMessage(
                messageId: Self.repliedId,
                quote: Sample.quote(text: "quoted"),
                origin: Sample.originUser(2001)
            )
        )

        let resolved = await resolve(fixture.service, reply)

        XCTAssertEqual(resolved, reply)
        XCTAssertEqual(fixture.transport.requests(ofType: "getMessage").count, 0)
    }

    // MARK: - Cache

    func testFetchedMessageIsReusedForTheNextPage() async throws {
        let fixture = fixture(replied: { Self.repliedMessage(content: Self.text("Original text")) })
        defer { fixture.finish() }
        let reply = try unresolvedReply(fixture.service)

        _ = await resolve(fixture.service, reply)
        let second = await resolve(fixture.service, reply)

        XCTAssertEqual(second.replyToPreview?.text, "Original text")
        XCTAssertEqual(fixture.transport.requests(ofType: "getMessage").count, 1)
    }

    func testSentMessageIsCachedForRepliesToIt() async throws {
        let fixture = fixture(replied: { nil })
        defer { fixture.finish() }
        var sent = Sample.message(id: Self.repliedId, content: Self.text("Sent from here"))
        sent["is_outgoing"] = true
        fixture.service.handleUpdate([
            "@type": "updateMessageSendSucceeded",
            "old_message_id": -1,
            "message": sent
        ])

        let resolved = try await resolve(fixture.service, unresolvedReply(fixture.service))

        XCTAssertEqual(resolved.replyToPreview?.text, "Sent from here")
        XCTAssertEqual(fixture.transport.requests(ofType: "getMessage").count, 0)
    }
}
