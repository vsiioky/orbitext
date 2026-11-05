import XCTest
@testable import OrbitextWatch

/// ReplyMarkup <- generated TDApi mapping, ChatReplyKeyboard rules, and the
/// way MessageInfo carries the parsed markup (parse + Codable snapshots).
final class ReplyMarkupMappingTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Helpers

    private func inlineButton(_ text: String, type: [String: Any], style: String? = nil) -> [String: Any] {
        var button: [String: Any] = ["@type": "inlineKeyboardButton", "text": text, "type": type]
        if let style { button["style"] = ["@type": style] as [String: Any] }
        return button
    }

    private func callbackButton(_ text: String, data: String = "AQID") -> [String: Any] {
        inlineButton(text, type: ["@type": "inlineKeyboardButtonTypeCallback", "data": data])
    }

    private func inlineKeyboard(_ rows: [[[String: Any]]]) -> [String: Any] {
        ["@type": "replyMarkupInlineKeyboard", "rows": rows]
    }

    private func replyButton(_ text: String, type: String? = "keyboardButtonTypeText", style: String? = nil) -> [String: Any] {
        var button: [String: Any] = ["@type": "keyboardButton", "text": text]
        if let type { button["type"] = ["@type": type] as [String: Any] }
        if let style { button["style"] = ["@type": style] as [String: Any] }
        return button
    }

    private func showKeyboard(_ rows: [[[String: Any]]], extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = ["@type": "replyMarkupShowKeyboard", "rows": rows]
        dict.merge(extra) { _, new in new }
        return dict
    }

    private func markup(_ dict: [String: Any]) -> ReplyMarkup? {
        ReplyMarkup(tdApi: TDApi.decodeReplyMarkup(dict))
    }

    private func button(_ dict: [String: Any]) -> InlineKeyboardButton? {
        InlineKeyboardButton(tdApi: TDApi.decodeInlineKeyboardButton(dict))
    }

    private func action(of type: [String: Any]) -> InlineKeyboardButton.Action? {
        button(["text": "B", "type": type])?.action
    }

    private func parsedRows(_ dict: [String: Any]) -> [[InlineKeyboardButton]]? {
        guard case .inlineKeyboard(let rows)? = markup(dict) else { return nil }
        return rows
    }

    private func parsedKeyboard(_ dict: [String: Any]) -> ReplyKeyboard? {
        guard case .showKeyboard(let keyboard)? = markup(dict) else { return nil }
        return keyboard
    }

    // MARK: - Inline button types

    func testCallbackButtonKeepsItsBytesAsTheBase64TheServerTakesBack() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeCallback", "data": "AQID/+8="])

        XCTAssertEqual(result, .callback(data: "AQID/+8="))
    }

    func testCallbackButtonWithoutDataIsDropped() {
        let missing: [String: Any] = ["@type": "inlineKeyboardButtonTypeCallback"]
        let empty: [String: Any] = ["@type": "inlineKeyboardButtonTypeCallback", "data": ""]
        let null: [String: Any] = ["@type": "inlineKeyboardButtonTypeCallback", "data": NSNull()]

        for type in [missing, empty, null] {
            XCTAssertNil(button(["text": "B", "type": type]), "type: \(type)")
        }
    }

    func testCallbackWithoutDataIsRemovedFromRowButSiblingsSurvive() throws {
        let broken = inlineButton("Broken", type: ["@type": "inlineKeyboardButtonTypeCallback"])
        let dict = inlineKeyboard([[broken, callbackButton("Ok", data: "b2s=")]])

        let rows = try XCTUnwrap(parsedRows(dict))

        XCTAssertEqual(rows, [[InlineKeyboardButton(text: "Ok", action: .callback(data: "b2s="))]])
    }

    func testKeyboardWhoseOnlyButtonLacksCallbackDataIsNil() {
        let broken = inlineButton("Broken", type: ["@type": "inlineKeyboardButtonTypeCallback"])

        XCTAssertNil(markup(inlineKeyboard([[broken]])))
    }

    func testUrlButtonKeepsUrl() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeUrl", "url": "https://example.com/a?b=1"])

        XCTAssertEqual(result, .url("https://example.com/a?b=1"))
    }

    func testLoginUrlButtonKeepsUrl() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeLoginUrl", "url": "https://example.com/login", "id": 7])

        XCTAssertEqual(result, .loginUrl("https://example.com/login"))
    }

    func testWebAppButtonKeepsUrl() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeWebApp", "url": "https://app.example.com"])

        XCTAssertEqual(result, .webApp("https://app.example.com"))
    }

    func testUrlButtonWithoutUrlFallsBackToEmptyString() {
        XCTAssertEqual(action(of: ["@type": "inlineKeyboardButtonTypeUrl"]), .url(""))
    }

    func testCopyTextButtonReadsTextField() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeCopyText", "text": "PROMO-2024"])

        XCTAssertEqual(result, .copyText("PROMO-2024"))
    }

    func testUserButtonWithNumericUserId() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeUser", "user_id": 123_456])

        XCTAssertEqual(result, .user(userId: 123_456))
    }

    func testUserButtonWithInt64UserIdAboveInt32() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeUser", "user_id": Int64(7_000_000_000)])

        XCTAssertEqual(result, .user(userId: 7_000_000_000))
    }

    func testUserButtonWithStringUserId() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeUser", "user_id": "7000000001"])

        XCTAssertEqual(result, .user(userId: 7_000_000_001))
    }

    func testSwitchInlineButtonKeepsQueryAndIgnoresTargetChat() {
        let type: [String: Any] = [
            "@type": "inlineKeyboardButtonTypeSwitchInline",
            "query": "search cats",
            "target_chat": ["@type": "targetChatCurrent"] as [String: Any]
        ]

        XCTAssertEqual(action(of: type), .switchInline(query: "search cats"))
    }

    func testBuyButton() {
        XCTAssertEqual(action(of: ["@type": "inlineKeyboardButtonTypeBuy"]), .buy)
    }

    func testCallbackGameButton() {
        XCTAssertEqual(action(of: ["@type": "inlineKeyboardButtonTypeCallbackGame"]), .callbackGame)
    }

    func testCallbackWithPasswordButton() {
        let type: [String: Any] = ["@type": "inlineKeyboardButtonTypeCallbackWithPassword", "data": "AQID"]

        XCTAssertEqual(action(of: type), .callbackWithPassword)
    }

    func testUnknownButtonTypeBecomesUnsupportedWithTag() {
        let result = action(of: ["@type": "inlineKeyboardButtonTypeFuture"])

        XCTAssertEqual(result, .unsupported("inlineKeyboardButtonTypeFuture"))
    }

    func testButtonTypeWithoutTagBecomesUnsupportedWithEmptyTag() {
        XCTAssertEqual(action(of: ["url": "https://example.com"]), .unsupported(""))
    }

    func testButtonWithoutTypeOrWithoutTextIsDropped() {
        XCTAssertNil(button(["text": "No type"]))
        XCTAssertNil(button(["type": ["@type": "inlineKeyboardButtonTypeBuy"]]))
    }

    // MARK: - Button styles

    func testButtonStylesAreMapped() {
        let cases: [(String, BotButtonStyle)] = [
            ("buttonStylePrimary", .primary),
            ("buttonStyleDanger", .danger),
            ("buttonStyleSuccess", .success)
        ]
        for (tag, expected) in cases {
            let styled = button(inlineButton(
                "B", type: ["@type": "inlineKeyboardButtonTypeBuy"], style: tag
            ))
            XCTAssertEqual(styled?.style, expected, tag)
        }
    }

    func testMissingOrUnknownStyleIsStandard() {
        let plain = button(inlineButton("B", type: ["@type": "inlineKeyboardButtonTypeBuy"]))
        let standard = button(inlineButton(
            "B", type: ["@type": "inlineKeyboardButtonTypeBuy"], style: "buttonStyleDefault"
        ))
        let unknown = button(inlineButton(
            "B", type: ["@type": "inlineKeyboardButtonTypeBuy"], style: "buttonStyleHolographic"
        ))

        XCTAssertEqual(plain?.style, .standard)
        XCTAssertEqual(standard?.style, .standard)
        XCTAssertEqual(unknown?.style, .standard)
    }

    // MARK: - Inline keyboard shape

    func testInlineKeyboardKeepsRowStructureAndOrder() throws {
        let dict = inlineKeyboard([
            [callbackButton("A", data: "QQ=="), callbackButton("B", data: "Qg==")],
            [callbackButton("C", data: "Qw==")]
        ])

        let rows = try XCTUnwrap(parsedRows(dict))

        XCTAssertEqual(rows.map { $0.map(\.text) }, [["A", "B"], ["C"]])
    }

    func testRowsWithOnlyInvalidButtonsAreDropped() throws {
        let invalid = inlineButton("X", type: ["@type": "inlineKeyboardButtonTypeCallback"])
        let dict = inlineKeyboard([[invalid, invalid], [callbackButton("Ok")], [invalid]])

        let rows = try XCTUnwrap(parsedRows(dict))

        XCTAssertEqual(rows.map { $0.map(\.text) }, [["Ok"]])
    }

    func testInlineKeyboardWithNoValidButtonsIsNil() {
        let invalid = inlineButton("X", type: ["@type": "inlineKeyboardButtonTypeCallback"])

        XCTAssertNil(markup(inlineKeyboard([[invalid], [invalid]])))
    }

    func testInlineKeyboardWithEmptyOrMissingRowsIsNil() {
        XCTAssertNil(markup(inlineKeyboard([])))
        XCTAssertNil(markup(inlineKeyboard([[]])))
        XCTAssertNil(markup(["@type": "replyMarkupInlineKeyboard"]))
    }

    func testInlineKeyboardMixesEveryButtonTypeInOneMessage() throws {
        let dict = inlineKeyboard([[
            callbackButton("cb"),
            inlineButton("url", type: ["@type": "inlineKeyboardButtonTypeUrl", "url": "https://t.me/bot"]),
            inlineButton("buy", type: ["@type": "inlineKeyboardButtonTypeBuy"])
        ]])

        let rows = try XCTUnwrap(parsedRows(dict))

        XCTAssertEqual(rows.first?.map(\.action), [.callback(data: "AQID"), .url("https://t.me/bot"), .buy])
    }

    // MARK: - Show keyboard

    func testShowKeyboardFlagsAndPlaceholder() throws {
        let dict = showKeyboard([[replyButton("Yes")]], extra: [
            "one_time": true,
            "is_persistent": true,
            "input_field_placeholder": "Choose"
        ])

        let keyboard = try XCTUnwrap(parsedKeyboard(dict))

        XCTAssertTrue(keyboard.isOneTime)
        XCTAssertTrue(keyboard.isPersistent)
        XCTAssertEqual(keyboard.placeholder, "Choose")
    }

    func testShowKeyboardFlagsDefaultToFalseAndEmptyPlaceholder() throws {
        let keyboard = try XCTUnwrap(parsedKeyboard(showKeyboard([[replyButton("Yes")]])))

        XCTAssertFalse(keyboard.isOneTime)
        XCTAssertFalse(keyboard.isPersistent)
        XCTAssertFalse(keyboard.isPersonal)
        XCTAssertEqual(keyboard.placeholder, "")
    }

    func testShowKeyboardReadsIsPersonal() throws {
        let personal = try XCTUnwrap(parsedKeyboard(showKeyboard([[replyButton("Yes")]], extra: ["is_personal": true])))
        let shared = try XCTUnwrap(parsedKeyboard(showKeyboard([[replyButton("Yes")]], extra: ["is_personal": false])))

        XCTAssertTrue(personal.isPersonal)
        XCTAssertFalse(shared.isPersonal)
    }

    func testUsedOneTimeKeyboardIsCollapsedAndHasNoPlaceholder() throws {
        let dict = showKeyboard([[replyButton("Yes")]], extra: [
            "one_time": true,
            "is_personal": false,
            "input_field_placeholder": "Choose"
        ])
        let parsed = try XCTUnwrap(markup(dict))
        let chatKeyboard = try XCTUnwrap(ChatReplyKeyboard(messageId: 3, markup: parsed))

        XCTAssertEqual(chatKeyboard.keyboard?.isCollapsed, true)
        XCTAssertFalse(chatKeyboard.isAwaitingInput)
        XCTAssertNil(chatKeyboard.placeholder)
    }

    func testConsumedCollapsesOneTimeKeyboardAndDropsOthers() throws {
        let oneTime = try XCTUnwrap(ChatReplyKeyboard(messageId: 4, markup: .showKeyboard(ReplyKeyboard(
            rows: [[ReplyKeyboardButton(text: "Go", kind: .text)]],
            isOneTime: true
        ))))
        let regular = try XCTUnwrap(ChatReplyKeyboard(messageId: 4, markup: keyboardMarkup()))
        let forceReply = try XCTUnwrap(ChatReplyKeyboard(messageId: 4, markup: .forceReply(placeholder: "x")))

        XCTAssertTrue(oneTime.isAwaitingInput)
        let consumed = try XCTUnwrap(oneTime.consumed())
        XCTAssertEqual(consumed.messageId, 4)
        XCTAssertEqual(consumed.keyboard?.isCollapsed, true)
        XCTAssertNil(regular.consumed())
        XCTAssertNil(forceReply.consumed())
    }

    func testReplyKeyboardButtonKinds() throws {
        let dict = showKeyboard([[
            replyButton("text", type: "keyboardButtonTypeText"),
            replyButton("missing", type: nil),
            replyButton("loc", type: "keyboardButtonTypeRequestLocation"),
            replyButton("phone", type: "keyboardButtonTypeRequestPhoneNumber"),
            replyButton("poll", type: "keyboardButtonTypeRequestPoll"),
            replyButton("webapp", type: "keyboardButtonTypeWebApp")
        ]])

        let keyboard = try XCTUnwrap(parsedKeyboard(dict))

        XCTAssertEqual(keyboard.rows.first?.map(\.kind), [
            .text,
            .text,
            .requestLocation,
            .requestPhoneNumber,
            .unsupported("keyboardButtonTypeRequestPoll"),
            .unsupported("keyboardButtonTypeWebApp")
        ])
    }

    func testReplyKeyboardButtonIsSupportedExcludesOnlyUnsupportedKinds() {
        XCTAssertTrue(ReplyKeyboardButton(text: "a", kind: .text).isSupported)
        XCTAssertTrue(ReplyKeyboardButton(text: "a", kind: .requestLocation).isSupported)
        XCTAssertTrue(ReplyKeyboardButton(text: "a", kind: .requestPhoneNumber).isSupported)
        XCTAssertFalse(ReplyKeyboardButton(text: "a", kind: .unsupported("x")).isSupported)
    }

    func testReplyKeyboardButtonStyleAndTextRequirement() throws {
        let dict = showKeyboard([[
            replyButton("Go", style: "buttonStyleSuccess"),
            ["@type": "keyboardButton", "type": ["@type": "keyboardButtonTypeText"]] as [String: Any]
        ]])

        let keyboard = try XCTUnwrap(parsedKeyboard(dict))

        XCTAssertEqual(keyboard.rows, [[ReplyKeyboardButton(text: "Go", style: .success, kind: .text)]])
    }

    func testShowKeyboardKeepsRowStructureAndDropsEmptiedRows() throws {
        let noText: [String: Any] = ["@type": "keyboardButton"]
        let dict = showKeyboard([[replyButton("A"), replyButton("B")], [noText], [replyButton("C")]])

        let keyboard = try XCTUnwrap(parsedKeyboard(dict))

        XCTAssertEqual(keyboard.rows.map { $0.map(\.text) }, [["A", "B"], ["C"]])
    }

    func testShowKeyboardWithoutRowsStillParsesWithEmptyRows() throws {
        let keyboard = try XCTUnwrap(parsedKeyboard(showKeyboard([])))

        XCTAssertTrue(keyboard.rows.isEmpty)
    }

    // MARK: - Remove keyboard / force reply

    func testRemoveKeyboard() {
        let dict: [String: Any] = ["@type": "replyMarkupRemoveKeyboard", "is_personal": true]

        XCTAssertEqual(markup(dict), .removeKeyboard)
    }

    func testForceReplyKeepsPlaceholder() {
        let dict: [String: Any] = ["@type": "replyMarkupForceReply", "input_field_placeholder": "Your name"]

        XCTAssertEqual(markup(dict), .forceReply(placeholder: "Your name"))
    }

    func testForceReplyWithoutPlaceholderUsesEmptyString() {
        XCTAssertEqual(markup(["@type": "replyMarkupForceReply"]), .forceReply(placeholder: ""))
    }

    // MARK: - Absent / unknown input

    func testMissingAndUnknownMarkupKindsYieldNil() {
        XCTAssertNil(markup([String: Any]()))
        XCTAssertNil(markup(["rows": []] as [String: Any]))
        XCTAssertNil(markup(["@type": "replyMarkupFuture"] as [String: Any]))
    }

    func testMarkupFromJSONSerializationParses() {
        let inline = TDJSONSample.object("""
        {"@type":"replyMarkupInlineKeyboard","rows":[[\
        {"@type":"inlineKeyboardButton","text":"Go","icon_custom_emoji_id":"0",\
        "style":{"@type":"buttonStyleDefault"},\
        "type":{"@type":"inlineKeyboardButtonTypeUrl","url":"https://example.com"}}]]}
        """)
        let show = TDJSONSample.object("""
        {"@type":"replyMarkupShowKeyboard","rows":[[\
        {"@type":"keyboardButton","text":"Yes","icon_custom_emoji_id":"0",\
        "style":{"@type":"buttonStyleDefault"},"type":{"@type":"keyboardButtonTypeText"}}]],\
        "is_persistent":false,"resize_keyboard":true,"one_time":true,"is_personal":false,\
        "input_field_placeholder":""}
        """)

        XCTAssertEqual(
            markup(inline)?.inlineKeyboardRows,
            [[InlineKeyboardButton(text: "Go", action: .url("https://example.com"))]]
        )
        guard case .showKeyboard(let keyboard)? = markup(show) else {
            return XCTFail("expected showKeyboard")
        }
        XCTAssertTrue(keyboard.isOneTime)
        XCTAssertEqual(keyboard.rows, [[ReplyKeyboardButton(text: "Yes", kind: .text)]])
    }

    func testDictionaryAndArrayHelpersRejectOtherTypes() {
        XCTAssertNil(ReplyMarkup.dictionary(nil))
        XCTAssertNil(ReplyMarkup.dictionary("text"))
        XCTAssertNil(ReplyMarkup.dictionary([1, 2]))
        XCTAssertEqual(ReplyMarkup.dictionary(NSDictionary(dictionary: ["a": 1]))?["a"] as? Int, 1)
        XCTAssertTrue(ReplyMarkup.array(nil).isEmpty)
        XCTAssertTrue(ReplyMarkup.array("text").isEmpty)
        XCTAssertEqual(ReplyMarkup.array(NSArray(array: [1, 2])).count, 2)
    }

    // MARK: - Convenience accessors

    func testInlineKeyboardRowsOnlyForNonEmptyInlineKeyboards() {
        let row = [InlineKeyboardButton(text: "A", action: .buy)]

        XCTAssertEqual(ReplyMarkup.inlineKeyboard([row]).inlineKeyboardRows, [row])
        XCTAssertNil(ReplyMarkup.inlineKeyboard([]).inlineKeyboardRows)
        XCTAssertNil(ReplyMarkup.removeKeyboard.inlineKeyboardRows)
        XCTAssertNil(ReplyMarkup.forceReply(placeholder: "x").inlineKeyboardRows)
        XCTAssertNil(ReplyMarkup.showKeyboard(ReplyKeyboard(rows: [])).inlineKeyboardRows)
    }

    func testOpensLinkOnlyForUrlLoginUrlAndWebApp() {
        let opening: [InlineKeyboardButton.Action] = [.url("u"), .loginUrl("u"), .webApp("u")]
        let staying: [InlineKeyboardButton.Action] = [
            .callback(data: "AQID"), .callbackWithPassword, .callbackGame, .switchInline(query: "q"),
            .buy, .user(userId: 1), .copyText("t"), .unsupported("x")
        ]

        for action in opening {
            XCTAssertTrue(InlineKeyboardButton(text: "b", action: action).opensLink, "\(action)")
        }
        for action in staying {
            XCTAssertFalse(InlineKeyboardButton(text: "b", action: action).opensLink, "\(action)")
        }
    }

    // MARK: - ChatReplyKeyboard

    private func keyboardMarkup(placeholder: String = "") -> ReplyMarkup {
        .showKeyboard(ReplyKeyboard(rows: [[ReplyKeyboardButton(text: "Yes", kind: .text)]], placeholder: placeholder))
    }

    func testChatReplyKeyboardRejectsMarkupThatDoesNotStayActive() {
        let inline = ReplyMarkup.inlineKeyboard([[InlineKeyboardButton(text: "A", action: .buy)]])

        XCTAssertNil(ChatReplyKeyboard(messageId: 5, markup: inline))
        XCTAssertNil(ChatReplyKeyboard(messageId: 5, markup: .removeKeyboard))
        XCTAssertNil(ChatReplyKeyboard(messageId: 5, markup: .showKeyboard(ReplyKeyboard(rows: []))))
        XCTAssertNil(ChatReplyKeyboard(messageId: 5, markup: nil))
    }

    func testChatReplyKeyboardRejectsZeroMessageId() {
        XCTAssertNil(ChatReplyKeyboard(messageId: 0, markup: keyboardMarkup()))
        XCTAssertNil(ChatReplyKeyboard(messageId: 0, markup: .forceReply(placeholder: "x")))
    }

    func testChatReplyKeyboardAcceptsShowKeyboard() throws {
        let chatKeyboard = try XCTUnwrap(ChatReplyKeyboard(messageId: 5, markup: keyboardMarkup()))

        XCTAssertEqual(chatKeyboard.messageId, 5)
        XCTAssertEqual(chatKeyboard.keyboard?.rows.count, 1)
        XCTAssertNil(chatKeyboard.forceReplyPlaceholder)
    }

    func testChatReplyKeyboardAcceptsForceReplyEvenWithEmptyPlaceholder() throws {
        let chatKeyboard = try XCTUnwrap(ChatReplyKeyboard(messageId: 6, markup: .forceReply(placeholder: "")))

        XCTAssertNil(chatKeyboard.keyboard)
        XCTAssertEqual(chatKeyboard.forceReplyPlaceholder, "")
    }

    func testChatReplyKeyboardPlaceholderComesFromKeyboardOrForceReplyAndEmptyIsNil() throws {
        let fromKeyboard = try XCTUnwrap(ChatReplyKeyboard(messageId: 1, markup: keyboardMarkup(placeholder: "Pick")))
        let emptyKeyboard = try XCTUnwrap(ChatReplyKeyboard(messageId: 1, markup: keyboardMarkup(placeholder: "")))
        let fromForceReply = try XCTUnwrap(ChatReplyKeyboard(messageId: 2, markup: .forceReply(placeholder: "Reply")))
        let emptyForceReply = try XCTUnwrap(ChatReplyKeyboard(messageId: 2, markup: .forceReply(placeholder: "")))

        XCTAssertEqual(fromKeyboard.placeholder, "Pick")
        XCTAssertNil(emptyKeyboard.placeholder)
        XCTAssertEqual(fromForceReply.placeholder, "Reply")
        XCTAssertNil(emptyForceReply.placeholder)
    }

    // MARK: - MessageInfo integration

    private func minimalMessage(replyMarkup: Any? = nil, includeMarkup: Bool = true) -> [String: Any] {
        var message: [String: Any] = [
            "@type": "message",
            "id": Int64(101),
            "chat_id": Int64(42),
            "date": 1_700_000_000,
            "is_outgoing": false,
            "sender_id": ["@type": "messageSenderUser", "user_id": Int64(9)] as [String: Any],
            "content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "Pick one", "entities": [Any]()] as [String: Any]
            ] as [String: Any]
        ]
        if includeMarkup { message["reply_markup"] = replyMarkup ?? NSNull() }
        return message
    }

    func testParseMessageInfoFillsReplyMarkup() throws {
        let dict = minimalMessage(replyMarkup: inlineKeyboard([[callbackButton("Go", data: "AQID")]]))

        let message = try XCTUnwrap(service.parseMessageInfo(dict))

        XCTAssertEqual(message.id, 101)
        XCTAssertEqual(
            message.replyMarkup,
            .inlineKeyboard([[InlineKeyboardButton(text: "Go", action: .callback(data: "AQID"))]])
        )
    }

    func testParseMessageInfoKeepsWebAppAndCopyTextButtons() throws {
        let dict = minimalMessage(replyMarkup: inlineKeyboard([[
            inlineButton("app", type: ["@type": "inlineKeyboardButtonTypeWebApp", "url": "https://app.example.com"]),
            inlineButton("copy", type: ["@type": "inlineKeyboardButtonTypeCopyText", "text": "XYZ"])
        ]]))

        let message = try XCTUnwrap(service.parseMessageInfo(dict))

        XCTAssertEqual(message.replyMarkup?.inlineKeyboardRows?.first?.map(\.action), [
            .webApp("https://app.example.com"),
            .copyText("XYZ")
        ])
    }

    func testParseMessageInfoWithShowKeyboardMarkup() throws {
        let dict = minimalMessage(replyMarkup: showKeyboard([[replyButton("Yes")]], extra: ["one_time": true]))

        let message = try XCTUnwrap(service.parseMessageInfo(dict))

        guard case .showKeyboard(let keyboard)? = message.replyMarkup else {
            return XCTFail("expected showKeyboard")
        }
        XCTAssertTrue(keyboard.isOneTime)
    }

    func testParseMessageInfoWithoutReplyMarkupLeavesNil() throws {
        let absent = try XCTUnwrap(service.parseMessageInfo(minimalMessage(includeMarkup: false)))
        let null = try XCTUnwrap(service.parseMessageInfo(minimalMessage()))

        XCTAssertNil(absent.replyMarkup)
        XCTAssertNil(null.replyMarkup)
    }

    private func sampleMessage(replyMarkup: ReplyMarkup?) -> MessageInfo {
        MessageInfo(
            id: 7,
            chatId: 3,
            senderName: "Bot",
            senderId: 99,
            content: .text("Menu"),
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            isOutgoing: false,
            isRead: false,
            replyMarkup: replyMarkup
        )
    }

    func testMessageInfoJSONRoundTripKeepsEveryReplyMarkupCase() throws {
        let inlineRows = [[
            InlineKeyboardButton(text: "cb", style: .primary, action: .callback(data: "AQID")),
            InlineKeyboardButton(text: "user", action: .user(userId: 7_000_000_000)),
            InlineKeyboardButton(text: "x", style: .danger, action: .unsupported("future"))
        ]]
        let keyboard = ReplyKeyboard(
            rows: [[ReplyKeyboardButton(text: "Phone", style: .success, kind: .requestPhoneNumber)]],
            isOneTime: true,
            isPersistent: true,
            placeholder: "Pick"
        )
        let markups: [ReplyMarkup?] = [
            .inlineKeyboard(inlineRows), .showKeyboard(keyboard), .removeKeyboard, .forceReply(placeholder: "Name"), nil
        ]

        for markup in markups {
            let original = sampleMessage(replyMarkup: markup)
            let decoded = try JSONDecoder().decode(MessageInfo.self, from: JSONEncoder().encode(original))

            XCTAssertEqual(decoded.replyMarkup, markup, "\(String(describing: markup))")
            XCTAssertEqual(decoded, original)
        }
    }

    func testSnapshotWithoutReplyMarkupKeyDecodesToNil() throws {
        let original = sampleMessage(replyMarkup: .removeKeyboard)
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["replyMarkup"], "fixture must contain the key before it is stripped")
        json.removeValue(forKey: "replyMarkup")

        let legacy = try JSONDecoder().decode(MessageInfo.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(legacy.replyMarkup)
        XCTAssertEqual(legacy.id, original.id)
    }
}
