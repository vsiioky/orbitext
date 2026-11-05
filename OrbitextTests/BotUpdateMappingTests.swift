import XCTest
@testable import OrbitextWatch

/// Bot-related TDLib updates: keyboard swaps on edited messages, content
/// replacement, and the chat-level reply keyboard (updateChatReplyMarkup).
/// The events stream is single-consumer, so every test reads all of its
/// expected events through one iterator via collectEvents.
final class BotUpdateMappingTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Helpers

    /// Reads up to `count` events through a single iterator, returning early
    /// once they have arrived and with whatever arrived once `timeout` passes.
    private func collectEvents(count: Int, timeout: TimeInterval = 1.0) async -> [TDLibEvent] {
        await withTaskGroup(of: [TDLibEvent].self) { group in
            group.addTask { [events = service.events] in
                var collected: [TDLibEvent] = []
                guard count > 0 else { return collected }
                for await event in events {
                    collected.append(event)
                    if collected.count == count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            var best: [TDLibEvent] = []
            for await result in group {
                if result.count > best.count { best = result }
                group.cancelAll()
            }
            return best
        }
    }

    private func handle(_ dict: [String: Any]) -> Bool {
        service.handleUpdateTyped(dict)
    }

    private var inlineKeyboardDict: [String: Any] {
        let button: [String: Any] = [
            "@type": "inlineKeyboardButton",
            "text": "Go",
            "type": ["@type": "inlineKeyboardButtonTypeCallback", "data": "AQID"] as [String: Any]
        ]
        return ["@type": "replyMarkupInlineKeyboard", "rows": [[button]]]
    }

    private var showKeyboardDict: [String: Any] {
        let button: [String: Any] = [
            "@type": "keyboardButton",
            "text": "Yes",
            "type": ["@type": "keyboardButtonTypeText"] as [String: Any]
        ]
        return ["@type": "replyMarkupShowKeyboard", "rows": [[button]], "one_time": true]
    }

    private func makeMessage(id: Int64, chatId: Int64, replyMarkup: [String: Any]?) -> [String: Any] {
        var dict: [String: Any] = [
            "@type": "message",
            "id": id,
            "chat_id": chatId,
            "date": 1_700_000_000,
            "is_outgoing": false,
            "sender_id": ["@type": "messageSenderUser", "user_id": Int64(9)] as [String: Any],
            "content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "Menu", "entities": [Any]()] as [String: Any]
            ] as [String: Any]
        ]
        if let replyMarkup { dict["reply_markup"] = replyMarkup }
        return dict
    }

    // MARK: - updateMessageEdited

    func testMessageEditedWithInlineKeyboardEmitsInvalidationThenMarkup() async {
        let dict: [String: Any] = [
            "@type": "updateMessageEdited",
            "chat_id": 3,
            "message_id": 9,
            "edit_date": 1_700_000_000,
            "reply_markup": inlineKeyboardDict
        ]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2)

        XCTAssertEqual(events.count, 2)
        guard events.count == 2,
              case .messagePropertiesInvalidated(let invalidatedChat, let invalidatedMessage) = events[0],
              case .messageReplyMarkupChanged(let chatId, let messageId, let replyMarkup) = events[1] else {
            return XCTFail("expected invalidation then markup change, got \(events)")
        }
        XCTAssertEqual(invalidatedChat, 3)
        XCTAssertEqual(invalidatedMessage, 9)
        XCTAssertEqual(chatId, 3)
        XCTAssertEqual(messageId, 9)
        XCTAssertEqual(
            replyMarkup,
            .inlineKeyboard([[InlineKeyboardButton(text: "Go", action: .callback(data: "AQID"))]])
        )
    }

    func testMessageEditedWithNullReplyMarkupEmitsNilMarkup() async {
        let dict: [String: Any] = [
            "@type": "updateMessageEdited",
            "chat_id": 3,
            "message_id": 9,
            "edit_date": 1_700_000_000,
            "reply_markup": NSNull()
        ]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2)

        XCTAssertEqual(events.count, 2)
        guard events.count == 2, case .messageReplyMarkupChanged(let chatId, let messageId, let replyMarkup) = events[1] else {
            return XCTFail("expected .messageReplyMarkupChanged second, got \(events)")
        }
        XCTAssertEqual(chatId, 3)
        XCTAssertEqual(messageId, 9)
        XCTAssertNil(replyMarkup)
    }

    func testMessageEditedWithoutReplyMarkupKeyEmitsNilMarkup() async {
        let dict: [String: Any] = ["@type": "updateMessageEdited", "chat_id": 3, "message_id": 9, "edit_date": 1]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2)

        guard events.count == 2, case .messageReplyMarkupChanged(_, _, let replyMarkup) = events[1] else {
            return XCTFail("expected .messageReplyMarkupChanged second, got \(events)")
        }
        XCTAssertNil(replyMarkup)
    }

    func testMessageEditedWithRemoveKeyboardMarkupIsReported() async {
        let dict: [String: Any] = [
            "@type": "updateMessageEdited",
            "chat_id": 3,
            "message_id": 9,
            "edit_date": 1,
            "reply_markup": ["@type": "replyMarkupRemoveKeyboard"]
        ]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2)

        guard events.count == 2, case .messageReplyMarkupChanged(_, _, let replyMarkup) = events[1] else {
            return XCTFail("expected .messageReplyMarkupChanged second, got \(events)")
        }
        XCTAssertEqual(replyMarkup, .removeKeyboard)
    }

    func testMessageEditedWithoutIdsIsNotConsumedAndEmitsNothing() async {
        let dict: [String: Any] = ["@type": "updateMessageEdited", "chat_id": 0, "message_id": 9, "reply_markup": NSNull()]

        XCTAssertFalse(handle(dict))
        let events = await collectEvents(count: 1, timeout: 0.2)

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - updateMessageContent

    func testMessageContentWithNewTextEmitsInvalidationThenContent() async {
        let dict: [String: Any] = [
            "@type": "updateMessageContent",
            "chat_id": 4,
            "message_id": 5,
            "new_content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "Updated menu", "entities": [Any]()] as [String: Any]
            ] as [String: Any]
        ]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2)

        XCTAssertEqual(events.count, 2)
        guard events.count == 2,
              case .messagePropertiesInvalidated(let invalidatedChat, let invalidatedMessage) = events[0],
              case .messageContentChanged(let chatId, let messageId, let content) = events[1] else {
            return XCTFail("expected invalidation then content change, got \(events)")
        }
        XCTAssertEqual(invalidatedChat, 4)
        XCTAssertEqual(invalidatedMessage, 5)
        XCTAssertEqual(chatId, 4)
        XCTAssertEqual(messageId, 5)
        XCTAssertEqual(content, .text(FormattedString(text: "Updated menu")))
    }

    func testMessageContentWithoutNewContentEmitsOnlyInvalidation() async {
        let dict: [String: Any] = ["@type": "updateMessageContent", "chat_id": 4, "message_id": 5]

        XCTAssertTrue(handle(dict))
        let events = await collectEvents(count: 2, timeout: 0.3)

        XCTAssertEqual(events.count, 1)
        guard case .messagePropertiesInvalidated? = events.first else {
            return XCTFail("expected only .messagePropertiesInvalidated, got \(events)")
        }
    }

    // MARK: - updateChatReplyMarkup

    func testChatReplyMarkupWithShowKeyboardEmitsChatReplyMarkupChanged() async {
        let update: [String: Any] = [
            "@type": "updateChatReplyMarkup",
            "chat_id": 7,
            "reply_markup_message": makeMessage(id: 55, chatId: 7, replyMarkup: showKeyboardDict)
        ]

        service.handleUpdate(update)
        let events = await collectEvents(count: 1)

        guard case .chatReplyMarkupChanged(let chatId, let message)? = events.first else {
            return XCTFail("expected .chatReplyMarkupChanged, got \(events)")
        }
        XCTAssertEqual(chatId, 7)
        XCTAssertEqual(message?.id, 55)
        guard case .showKeyboard(let keyboard)? = message?.replyMarkup else {
            return XCTFail("expected showKeyboard markup, got \(String(describing: message?.replyMarkup))")
        }
        XCTAssertTrue(keyboard.isOneTime)
        XCTAssertEqual(keyboard.rows, [[ReplyKeyboardButton(text: "Yes", kind: .text)]])
    }

    func testChatReplyMarkupAcceptsStringChatId() async {
        let update: [String: Any] = [
            "@type": "updateChatReplyMarkup",
            "chat_id": "7000000001",
            "reply_markup_message": makeMessage(id: 55, chatId: 7_000_000_001, replyMarkup: showKeyboardDict)
        ]

        service.handleUpdate(update)
        let events = await collectEvents(count: 1)

        guard case .chatReplyMarkupChanged(let chatId, let message)? = events.first else {
            return XCTFail("expected .chatReplyMarkupChanged, got \(events)")
        }
        XCTAssertEqual(chatId, 7_000_000_001)
        XCTAssertEqual(message?.id, 55)
    }

    func testChatReplyMarkupWithNullMessageEmitsNilMessage() async {
        let update: [String: Any] = [
            "@type": "updateChatReplyMarkup",
            "chat_id": 7,
            "reply_markup_message": NSNull()
        ]

        service.handleUpdate(update)
        let events = await collectEvents(count: 1)

        guard case .chatReplyMarkupChanged(let chatId, let message)? = events.first else {
            return XCTFail("expected .chatReplyMarkupChanged, got \(events)")
        }
        XCTAssertEqual(chatId, 7)
        XCTAssertNil(message)
    }

    func testChatReplyMarkupWithoutMessageKeyEmitsNilMessage() async {
        service.handleUpdate(["@type": "updateChatReplyMarkup", "chat_id": 7])
        let events = await collectEvents(count: 1)

        guard case .chatReplyMarkupChanged(let chatId, let message)? = events.first else {
            return XCTFail("expected .chatReplyMarkupChanged, got \(events)")
        }
        XCTAssertEqual(chatId, 7)
        XCTAssertNil(message)
    }

    func testChatReplyMarkupWithUnparseableMessageEmitsNilMessage() async {
        let update: [String: Any] = [
            "@type": "updateChatReplyMarkup",
            "chat_id": 7,
            "reply_markup_message": ["@type": "message", "id": 0] as [String: Any]
        ]

        service.handleUpdate(update)
        let events = await collectEvents(count: 1)

        guard case .chatReplyMarkupChanged(_, let message)? = events.first else {
            return XCTFail("expected .chatReplyMarkupChanged, got \(events)")
        }
        XCTAssertNil(message)
    }

    func testChatReplyMarkupWithZeroChatIdEmitsNothing() async {
        let update: [String: Any] = [
            "@type": "updateChatReplyMarkup",
            "chat_id": 0,
            "reply_markup_message": makeMessage(id: 55, chatId: 7, replyMarkup: showKeyboardDict)
        ]

        service.handleUpdate(update)
        let events = await collectEvents(count: 1, timeout: 0.2)

        XCTAssertTrue(events.isEmpty)
    }

    func testChatReplyMarkupWithoutChatIdEmitsNothing() async {
        service.handleUpdate(["@type": "updateChatReplyMarkup"])
        let events = await collectEvents(count: 1, timeout: 0.2)

        XCTAssertTrue(events.isEmpty)
    }

    func testChatReplyMarkupIsNotConsumedByTheTypedDispatcher() {
        let update: [String: Any] = ["@type": "updateChatReplyMarkup", "chat_id": 7]

        XCTAssertFalse(handle(update))
    }
}
