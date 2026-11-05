import XCTest
@testable import OrbitextWatch

/// What parseMessageInfo makes of the reply, forward, reaction and poll
/// members of a message, on TDLib 1.8.64 JSON (TDJSONSample). The tests pin
/// the result for each member and for the user and chat names resolved from
/// the service caches; they do not look at how the mapping reads the JSON.
final class MessageFieldParsingTests: XCTestCase {
    private typealias Sample = TDJSONSample

    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Helpers

    private func parse(_ message: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> MessageInfo {
        try XCTUnwrap(service.parseMessageInfo(message), file: file, line: line)
    }

    private func knowUser(_ id: Int64, _ firstName: String, _ lastName: String = "") {
        service.handleUpdate(Sample.updateUser(id: id, firstName: firstName, lastName: lastName))
    }

    private func knowChat(_ id: Int64, _ title: String) {
        service.chatCache.set(
            id,
            ChatInfo(id: id, title: title, lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
        )
    }

    // MARK: - Sender

    func testSenderIsNamedFromTheKnownUser() throws {
        knowUser(1002, "John", "Doe")

        let message = try parse(Sample.message())

        XCTAssertEqual(message.senderId, 1002)
        XCTAssertEqual(message.senderName, "John Doe")
        XCTAssertTrue(message.senderResolved)
    }

    func testUnknownIncomingSenderGetsAPlaceholderToResolveLater() throws {
        let message = try parse(Sample.message())

        XCTAssertEqual(message.senderName, L10n.string("User"))
        XCTAssertFalse(message.senderResolved)
    }

    func testSenderWithoutAnyNameKeepsThePlaceholderToResolveLater() throws {
        knowUser(1002, "")

        let message = try parse(Sample.message())

        XCTAssertEqual(message.senderName, L10n.string("User"), "a deleted account must not render a blank sender")
        XCTAssertFalse(message.senderResolved)
    }

    func testUnknownOutgoingSenderIsYou() throws {
        let message = try parse(Sample.message(isOutgoing: true))

        XCTAssertEqual(message.senderName, L10n.string("You"))
        XCTAssertFalse(message.senderResolved)
    }

    func testChatSenderIsNamedFromTheChatTitle() throws {
        knowChat(-1_002_233_445_566, "Tech Channel")
        var json = Sample.message()
        json["sender_id"] = Sample.object("""
        {"@type":"messageSenderChat","chat_id":-1002233445566}
        """)

        let message = try parse(json)

        XCTAssertEqual(message.senderId, -1_002_233_445_566)
        XCTAssertEqual(message.senderName, "Tech Channel")
    }

    // MARK: - reply_to

    func testReplyInTheSameChatCarriesOnlyTheMessageId() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage()))

        XCTAssertEqual(message.replyToMessageId, 3_141_592)
        XCTAssertNil(message.replyToSenderName)
        XCTAssertNil(message.replyToSenderUserId)
        XCTAssertNil(message.replyToPreview)
        XCTAssertFalse(message.replyToSenderResolved, "the name resolver fills it in later")
    }

    func testReplyToAMessageOfAnUnknownChatCarriesOnlyTheMessageId() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(chatId: 0)))

        XCTAssertEqual(message.replyToMessageId, 3_141_592)
        XCTAssertNil(message.replyToSenderName)
        XCTAssertFalse(message.replyToSenderResolved)
    }

    func testMessageWithoutReplyHasNoReplyFields() throws {
        let message = try parse(Sample.message())

        XCTAssertNil(message.replyToMessageId)
        XCTAssertNil(message.replyToSenderName)
        XCTAssertNil(message.replyToSenderUserId)
        XCTAssertNil(message.replyToPreview)
        XCTAssertTrue(message.replyToSenderResolved)
        XCTAssertFalse(message.hasReplyPreview)
    }

    func testReplyQuoteBecomesThePreviewWithItsEntities() throws {
        let quote = Sample.quote(text: "half of the line", entities: [
            Sample.entity(offset: 0, length: 4, type: "textEntityTypeBold"),
            Sample.entity(offset: 8, length: 2, type: "textEntityTypeSpoiler")
        ].joined(separator: ","))

        let message = try parse(Sample.message(members: Sample.replyToMessage(quote: quote)))

        XCTAssertEqual(message.replyToPreview, FormattedString(text: "half of the line", entities: [
            .bold(offset: 0, length: 4),
            .spoiler(offset: 8, length: 2)
        ]))
        XCTAssertTrue(message.hasReplyPreview)
    }

    func testReplyWithAnEmptyQuoteHasNoPreview() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(quote: Sample.quote(text: ""))))

        XCTAssertNil(message.replyToPreview)
    }

    func testReplyOriginUserIsNamedFromTheKnownUser() throws {
        knowUser(2001, "Reply", "Author")

        let message = try parse(Sample.message(members: Sample.replyToMessage(origin: Sample.originUser(2001))))

        XCTAssertEqual(message.replyToMessageId, 3_141_592)
        XCTAssertEqual(message.replyToSenderName, "Reply Author")
        XCTAssertEqual(message.replyToSenderUserId, 2001)
        XCTAssertTrue(message.replyToSenderResolved)
    }

    func testReplyOriginUserWhoIsNotKnownKeepsTheIdForTheResolver() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(origin: Sample.originUser(2001))))

        XCTAssertNil(message.replyToSenderName)
        XCTAssertEqual(message.replyToSenderUserId, 2001)
        XCTAssertFalse(message.replyToSenderResolved)
    }

    func testReplyOriginUserWithoutAnyNameIsLeftForTheResolver() throws {
        knowUser(2001, "")

        let message = try parse(Sample.message(members: Sample.replyToMessage(origin: Sample.originUser(2001))))

        XCTAssertNil(message.replyToSenderName, "a blank name is no name")
        XCTAssertEqual(message.replyToSenderUserId, 2001)
        XCTAssertFalse(message.replyToSenderResolved)
    }

    func testReplyOriginUserWithoutAnIdHasNoUserId() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(origin: Sample.originUser(0))))

        XCTAssertNil(message.replyToSenderUserId)
        XCTAssertFalse(message.replyToSenderResolved)
    }

    func testReplyOriginChatAndChannelAreNamedFromTheChatTitle() throws {
        knowChat(-1_001_111, "The Group")
        knowChat(-1_002_222, "The Channel")

        let viaChat = try parse(Sample.message(members: Sample.replyToMessage(
            origin: Sample.originChat(-1_001_111, signature: "Bob")
        )))
        let viaChannel = try parse(Sample.message(members: Sample.replyToMessage(
            origin: Sample.originChannel(-1_002_222)
        )))

        XCTAssertEqual(viaChat.replyToSenderName, "The Group")
        XCTAssertTrue(viaChat.replyToSenderResolved)
        XCTAssertNil(viaChat.replyToSenderUserId)
        XCTAssertEqual(viaChannel.replyToSenderName, "The Channel")
        XCTAssertTrue(viaChannel.replyToSenderResolved)
    }

    func testReplyOriginChatThatIsNotKnownStaysUnresolved() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(
            origin: Sample.originChannel(-1_002_222)
        )))

        XCTAssertNil(message.replyToSenderName)
        XCTAssertFalse(message.replyToSenderResolved)
    }

    func testReplyOriginHiddenUserIsNamedByTheOrigin() throws {
        let message = try parse(Sample.message(members: Sample.replyToMessage(
            origin: Sample.originHiddenUser("Anonymous Sender")
        )))

        XCTAssertEqual(message.replyToSenderName, "Anonymous Sender")
        XCTAssertNil(message.replyToSenderUserId)
        XCTAssertTrue(message.replyToSenderResolved)
    }

    func testReplyToAMessageOfAnotherChatReadsTheMessageId() throws {
        let original = """
        {"@type":"messageText","text":{"@type":"formattedText","text":"original","entities":[]}}
        """

        let message = try parse(Sample.message(members: Sample.replyToMessage(
            chatId: -1_005_550_001,
            origin: Sample.originHiddenUser("Elsewhere"),
            content: original
        )))

        XCTAssertEqual(message.replyToMessageId, 3_141_592)
        XCTAssertEqual(message.replyToSenderName, "Elsewhere")
    }

    func testReplyToAStoryIsNotAMessageReply() throws {
        let message = try parse(Sample.message(members: Sample.replyToStory))

        XCTAssertNil(message.replyToMessageId)
        XCTAssertNil(message.replyToSenderName)
        XCTAssertTrue(message.replyToSenderResolved)
    }

    func testReplyOfAFutureKindIsNotAMessageReply() throws {
        let message = try parse(Sample.message(members: """
        "reply_to":{"@type":"messageReplyToThread","message_id":3141592},
        """))

        XCTAssertNil(message.replyToMessageId)
        XCTAssertTrue(message.replyToSenderResolved)
    }

    // MARK: - forward_info.origin

    func testForwardOriginUserIsNamedFromTheKnownUser() throws {
        knowUser(2001, "Frank", "Forwarder")

        let message = try parse(Sample.message(members: Sample.forwardInfo(origin: Sample.originUser(2001))))

        XCTAssertEqual(message.forwardedOrigin, .user(userId: 2001, name: "Frank Forwarder"))
        XCTAssertEqual(message.forwardedFrom, "Frank Forwarder")
        XCTAssertTrue(message.isForwarded)
    }

    func testForwardOriginUserWhoIsNotKnownGetsAMarkerForTheResolver() throws {
        let message = try parse(Sample.message(members: Sample.forwardInfo(origin: Sample.originUser(2001))))

        XCTAssertEqual(message.forwardedOrigin, .user(userId: 2001, name: "#user:2001"))
    }

    func testForwardOriginUserWhoseNamesAreEmptyGetsTheMarkerToo() throws {
        knowUser(2001, "")

        let message = try parse(Sample.message(members: Sample.forwardInfo(origin: Sample.originUser(2001))))

        XCTAssertEqual(message.forwardedOrigin, .user(userId: 2001, name: "#user:2001"))
    }

    func testForwardOriginHiddenUser() throws {
        let message = try parse(Sample.message(members: Sample.forwardInfo(
            origin: Sample.originHiddenUser("Hidden Hannah")
        )))

        XCTAssertEqual(message.forwardedOrigin, .hiddenUser(name: "Hidden Hannah"))
    }

    func testForwardOriginChatKeepsTheSignature() throws {
        knowChat(-1_001_111, "The Group")

        let message = try parse(Sample.message(members: Sample.forwardInfo(
            origin: Sample.originChat(-1_001_111, signature: "Bob")
        )))

        XCTAssertEqual(message.forwardedOrigin, .chat(chatId: -1_001_111, title: "The Group", authorSignature: "Bob"))
        XCTAssertEqual(message.forwardedFrom, "The Group (Bob)")
    }

    func testForwardOriginChannelWithoutASignatureHasNone() throws {
        knowChat(-1_002_222, "The Channel")

        let message = try parse(Sample.message(members: Sample.forwardInfo(
            origin: Sample.originChannel(-1_002_222),
            source: Sample.forwardSource
        )))

        XCTAssertEqual(message.forwardedOrigin, .channel(chatId: -1_002_222, title: "The Channel", authorSignature: nil))
        XCTAssertTrue(message.forwardedOrigin?.isChannel ?? false)
        XCTAssertEqual(message.forwardedFrom, "The Channel")
    }

    func testForwardOriginChatThatIsNotKnownIsTitledWithAQuestionMark() throws {
        let message = try parse(Sample.message(members: Sample.forwardInfo(
            origin: Sample.originChannel(-1_002_222, signature: "Editor")
        )))

        XCTAssertEqual(message.forwardedOrigin, .channel(chatId: -1_002_222, title: "?", authorSignature: "Editor"))
    }

    func testForwardOfAFutureOriginKindIsNotShownAsForwarded() throws {
        let message = try parse(Sample.message(members: Sample.forwardInfo(
            origin: "{\"@type\":\"messageOriginNebula\",\"sender\":\"x\"}"
        )))

        XCTAssertNil(message.forwardedOrigin)
        XCTAssertFalse(message.isForwarded)
    }

    func testMessageWithoutForwardInfoIsNotForwarded() throws {
        let message = try parse(Sample.message())

        XCTAssertNil(message.forwardedOrigin)
    }

    // MARK: - interaction_info.reactions

    func testReactionsAreOrderedChosenFirstThenByCountThenByKey() throws {
        let reactions = [
            Sample.reaction(type: Sample.emojiReaction("🔥"), count: 9),
            Sample.reaction(type: Sample.emojiReaction("👍"), count: 5, isChosen: true),
            Sample.reaction(type: Sample.emojiReaction("😂"), count: 9),
            Sample.reaction(type: Sample.emojiReaction("🎉"), count: 1, isChosen: true)
        ]

        let message = try parse(Sample.message(members: Sample.interactionInfo(reactions: reactions)))

        XCTAssertEqual(message.reactions.map(\.emoji), ["👍", "🎉", "🔥", "😂"])
        XCTAssertEqual(message.reactions.map(\.count), [5, 1, 9, 9])
        XCTAssertEqual(message.reactions.map(\.isSelected), [true, true, false, false])
        XCTAssertEqual(message.reactions.first?.key, "emoji:👍")
        XCTAssertEqual(message.reactions.first?.actionValue, "👍")
    }

    func testEmojiReactionDropsTheVariationSelectorFromItsKeyAndActionValue() throws {
        let reactions = [Sample.reaction(type: Sample.emojiReaction("\u{2764}\u{FE0F}"), count: 2)]

        let message = try parse(Sample.message(members: Sample.interactionInfo(reactions: reactions)))

        let reaction = try XCTUnwrap(message.reactions.first)
        XCTAssertEqual(reaction.emoji, "\u{2764}\u{FE0F}")
        XCTAssertEqual(reaction.key, "emoji:\u{2764}")
        XCTAssertEqual(reaction.actionValue, "\u{2764}")
    }

    func testPaidReactionIsAStarWithoutAnActionValue() throws {
        let reactions = [Sample.reaction(type: Sample.paidReaction, count: 7)]

        let message = try parse(Sample.message(members: Sample.interactionInfo(reactions: reactions)))

        let reaction = try XCTUnwrap(message.reactions.first)
        XCTAssertEqual(reaction.key, "paid")
        XCTAssertEqual(reaction.emoji, "⭐")
        XCTAssertNil(reaction.actionValue)
        XCTAssertEqual(reaction.count, 7)
        XCTAssertFalse(reaction.isSelected)
    }

    func testCustomEmojiReactionIsKeyedByItsInt64Id() throws {
        let reactions = [Sample.reaction(
            type: Sample.customEmojiReaction("5368324170671202286"),
            count: 3,
            isChosen: true
        )]

        let message = try parse(Sample.message(members: Sample.interactionInfo(reactions: reactions)))

        let reaction = try XCTUnwrap(message.reactions.first)
        XCTAssertEqual(reaction.key, "custom:5368324170671202286")
        XCTAssertEqual(reaction.emoji, "✨")
        XCTAssertNil(reaction.actionValue)
        XCTAssertTrue(reaction.isSelected)
    }

    func testReactionOfAFutureKindIsDropped() throws {
        let reactions = [
            Sample.reaction(type: "{\"@type\":\"reactionTypeSomething\"}", count: 4),
            Sample.reaction(type: Sample.emojiReaction("👍"), count: 1)
        ]

        let message = try parse(Sample.message(members: Sample.interactionInfo(reactions: reactions)))

        XCTAssertEqual(message.reactions.map(\.key), ["emoji:👍"])
    }

    func testInteractionInfoWithoutReactionsHasNone() throws {
        let withoutReactions = try parse(Sample.message(members: Sample.interactionInfo(reactions: nil)))
        let withEmptyList = try parse(Sample.message(members: Sample.interactionInfo(reactions: [])))

        XCTAssertEqual(withoutReactions.reactions, [])
        XCTAssertEqual(withEmptyList.reactions, [])
    }

    func testMessageWithoutInteractionInfoHasNoReactions() throws {
        XCTAssertEqual(try parse(Sample.message()).reactions, [])
    }

    // MARK: - messagePoll

    func testPollShowsItsQuestionText() throws {
        let entities = Sample.entity(offset: 0, length: 8, type: "textEntityTypeBold")

        let message = try parse(Sample.message(content: Sample.poll(question: "Favorite color?", entities: entities)))

        XCTAssertEqual(message.content, .poll(question: "Favorite color?"))
    }

    func testQuizShowsItsQuestionText() throws {
        let quiz = """
        {"@type":"pollTypeQuiz","correct_option_ids":[1],\
        "explanation":{"@type":"formattedText","text":"Sky","entities":[]}}
        """

        let message = try parse(Sample.message(content: Sample.poll(question: "Sky color?", type: quiz)))

        XCTAssertEqual(message.content, .poll(question: "Sky color?"))
    }

    func testPollWithoutAQuestionHasAnEmptyOne() throws {
        let message = try parse(Sample.message(content: """
        {"@type":"messagePoll","poll":{"@type":"poll","id":"1","options":[],"total_voter_count":0},\
        "can_add_option":false}
        """))

        XCTAssertEqual(message.content, .poll(question: ""))
    }

    func testPollContentWithoutAPollHasAnEmptyQuestion() throws {
        let message = try parse(Sample.message(content: "{\"@type\":\"messagePoll\",\"can_add_option\":false}"))

        XCTAssertEqual(message.content, .poll(question: ""))
    }

    // MARK: - Chat last message

    func testChatLastMessageIsMappedLikeAMessage() {
        knowUser(2001, "Known", "User")
        let members = Sample.replyToMessage(origin: Sample.originUser(2001))
            + Sample.forwardInfo(origin: Sample.originHiddenUser("Hidden Hannah"))
            + Sample.interactionInfo(reactions: [Sample.reaction(type: Sample.emojiReaction("🔥"), count: 2)])
        let last = Sample.message(members: members, content: Sample.poll(question: "Lunch?"))
        var chat = Sample.chat()
        chat["last_message"] = last

        let info = service.parseChatInfo(chat)

        XCTAssertEqual(info.lastMessage, service.parseMessageInfo(last))
        XCTAssertEqual(info.lastMessage?.content, .poll(question: "Lunch?"))
        XCTAssertEqual(info.lastMessage?.replyToSenderName, "Known User")
        XCTAssertEqual(info.lastMessage?.forwardedOrigin, .hiddenUser(name: "Hidden Hannah"))
        XCTAssertEqual(info.lastMessage?.reactions.map(\.emoji), ["🔥"])
    }

    func testChatWithoutALastMessageHasNone() {
        XCTAssertNil(service.parseChatInfo(Sample.chat()).lastMessage)
    }

    func testChatCarriesItsUnreadReactionCount() {
        XCTAssertEqual(service.parseChatInfo(Sample.chat(unreadReactionCount: 4)).reactionCount, 4)
        XCTAssertEqual(service.parseChatInfo(Sample.chat()).reactionCount, 0)
    }

    // MARK: - Content with no mapping

    func testContentTheMappingDoesNotKnowIsUnsupportedByItsTag() throws {
        let dice = "{\"@type\":\"messageDice\",\"emoji\":\"🎲\",\"value\":4}"

        let message = try parse(Sample.message(content: dice))

        XCTAssertEqual(message.content, .unsupported("Dice"))
    }

    func testKnownContentWithoutItsPayloadIsUnsupportedByItsTag() throws {
        let message = try parse(Sample.message(content: "{\"@type\":\"messagePhoto\",\"is_secret\":false}"))

        XCTAssertEqual(message.content, .unsupported("Photo"))
    }

    // MARK: - updateMessageInteractionInfo

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

    func testInteractionInfoUpdateEmitsTheReactionsOfTheMessage() async {
        let reactions = [
            Sample.reaction(type: Sample.emojiReaction("🔥"), count: 2),
            Sample.reaction(type: Sample.emojiReaction("👍"), count: 5, isChosen: true)
        ]
        service.handleUpdate(Sample.object("""
        {"@type":"updateMessageInteractionInfo","chat_id":-1001234567890,"message_id":3145728,\
        "interaction_info":\(Sample.interactionInfoObject(reactions: reactions))}
        """))

        guard case .reactionsUpdated(let chatId, let messageId, let emitted)? = await nextEvent() else {
            return XCTFail("expected .reactionsUpdated")
        }
        XCTAssertEqual(chatId, -1_001_234_567_890)
        XCTAssertEqual(messageId, 3_145_728)
        XCTAssertEqual(emitted.map(\.emoji), ["👍", "🔥"])
        XCTAssertEqual(emitted.map(\.count), [5, 2])
    }

    func testInteractionInfoUpdateWithoutReactionsClearsThem() async {
        service.handleUpdate(Sample.object("""
        {"@type":"updateMessageInteractionInfo","chat_id":7,"message_id":88,\
        "interaction_info":\(Sample.interactionInfoObject(reactions: nil))}
        """))
        service.handleUpdate(Sample.object("""
        {"@type":"updateMessageInteractionInfo","chat_id":7,"message_id":89}
        """))

        for expectedMessageId: Int64 in [88, 89] {
            guard case .reactionsUpdated(let chatId, let messageId, let emitted)? = await nextEvent() else {
                return XCTFail("expected .reactionsUpdated for \(expectedMessageId)")
            }
            XCTAssertEqual(chatId, 7)
            XCTAssertEqual(messageId, expectedMessageId)
            XCTAssertEqual(emitted, [])
        }
    }
}
