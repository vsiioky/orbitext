import XCTest
@testable import OrbitextWatch

/// MessageManager+Bots: inline button presses, callback answers, link
/// routing and the phone-number share of reply keyboards.
@MainActor
final class MessageManagerBotTests: XCTestCase {
    private var service: MockTelegramService!
    private var queue: MessageQueue!
    private var manager: MessageManager!
    private var errorPresenter: ErrorPresenter!

    private let chatId: Int64 = 1
    private var notAvailable: String { L10n.string("Not available on Apple Watch") }

    override func setUp() async throws {
        try await super.setUp()
        service = MockTelegramService()
        queue = MessageQueue()
        queue.clear()
        manager = MessageManager(service: service, messageQueue: queue)
        errorPresenter = ErrorPresenter()
        manager.errorPresenter = errorPresenter
    }

    // MARK: - Fixtures

    private func botMessage(id: Int64 = 42, isSending: Bool = false) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: chatId,
            senderName: "Bot",
            senderId: 99,
            content: .text("Menu"),
            date: Date(),
            isOutgoing: false,
            isRead: false,
            isSending: isSending
        )
    }

    private func button(_ action: InlineKeyboardButton.Action) -> InlineKeyboardButton {
        InlineKeyboardButton(text: "Button", action: action)
    }

    private func press(_ action: InlineKeyboardButton.Action, in message: MessageInfo? = nil) async -> BotButtonResult {
        await manager.pressInlineButton(button(action), in: message ?? botMessage())
    }

    private func publicChat(id: Int64 = 500, title: String = "Some Bot") -> ChatInfo {
        ChatInfo(id: id, title: title, lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
    }

    // MARK: - Callback buttons

    func testCallbackButtonSendsExactBase64DataForTheMessage() async {
        let result = await press(.callback(data: "AQID/+=="), in: botMessage(id: 42))

        XCTAssertEqual(service.callbackQueries.count, 1)
        XCTAssertEqual(service.callbackQueries.first?.chatId, chatId)
        XCTAssertEqual(service.callbackQueries.first?.messageId, 42)
        XCTAssertEqual(service.callbackQueries.first?.data, "AQID/+==")
        XCTAssertEqual(result, .done)
    }

    func testEmptyCallbackAnswerIsDone() async {
        service.callbackAnswer = BotCallbackAnswer()

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .done)
        XCTAssertNil(errorPresenter.error)
    }

    func testCallbackAnswerTextBecomesNotice() async {
        service.callbackAnswer = BotCallbackAnswer(text: "Saved")

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .notice("Saved"))
    }

    func testCallbackAnswerWithShowAlertBecomesAlert() async {
        service.callbackAnswer = BotCallbackAnswer(text: "Are you sure?", showAlert: true)

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .alert("Are you sure?"))
    }

    func testCallbackAnswerShowAlertWithoutTextIsDone() async {
        service.callbackAnswer = BotCallbackAnswer(text: "", showAlert: true)

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .done)
    }

    func testCallbackAnswerWithTelegramUrlOpensChat() async {
        let chat = publicChat()
        service.publicChatsByUsername["somebot"] = chat
        service.callbackAnswer = BotCallbackAnswer(url: "https://t.me/somebot")

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .openChat(chat))
    }

    func testCallbackAnswerWithExternalUrlOpensLink() async throws {
        service.callbackAnswer = BotCallbackAnswer(url: "https://example.com/game")

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, try .openLink(XCTUnwrap(URL(string: "https://example.com/game"))))
    }

    func testCallbackAnswerUrlTakesPrecedenceOverText() async throws {
        service.callbackAnswer = BotCallbackAnswer(text: "Opening...", showAlert: true, url: "https://example.com/game")

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, try .openLink(XCTUnwrap(URL(string: "https://example.com/game"))))
    }

    func testBotNotRespondingBecomesNeutralNoticeWithoutErrorBanner() async {
        service.callbackQueryError = BotInteractionError.botNotResponding

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .notice(L10n.string("The bot did not respond")))
        XCTAssertNil(errorPresenter.error)
    }

    func testGenericCallbackErrorIsPresentedAndReturnsDone() async {
        service.callbackQueryError = TestError.failed("Boom")

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .done)
        XCTAssertEqual(errorPresenter.error, "Boom")
    }

    func testCancelledCallbackIsSilentlyDone() async {
        service.callbackQueryError = CancellationError()

        let result = await press(.callback(data: "AQID"))

        XCTAssertEqual(result, .done)
        XCTAssertNil(errorPresenter.error)
    }

    func testPressOnMessageStillSendingDoesNothing() async {
        let result = await press(.callback(data: "AQID"), in: botMessage(id: -1, isSending: true))

        XCTAssertEqual(result, .done)
        XCTAssertTrue(service.callbackQueries.isEmpty)
        XCTAssertNil(errorPresenter.error)
    }

    func testAnswerCallbackDirectlyUsesTheGivenIds() async {
        service.callbackAnswer = BotCallbackAnswer(text: "Hi")

        let result = await manager.answerCallback(chatId: 7, messageId: 8, data: "Zm9v")

        XCTAssertEqual(result, .notice("Hi"))
        XCTAssertEqual(service.callbackQueries.first?.chatId, 7)
        XCTAssertEqual(service.callbackQueries.first?.messageId, 8)
        XCTAssertEqual(service.callbackQueries.first?.data, "Zm9v")
    }

    // MARK: - URL buttons

    func testTelegramUrlButtonOpensPublicChat() async {
        let chat = publicChat()
        service.publicChatsByUsername["somebot"] = chat

        let result = await press(.url("https://t.me/somebot"))

        XCTAssertEqual(result, .openChat(chat))
        XCTAssertTrue(service.callbackQueries.isEmpty)
    }

    func testTelegramUrlButtonLooksUpTheUsernameCaseInsensitively() async {
        let chat = publicChat()
        service.publicChatsByUsername["somebot"] = chat

        let result = await press(.url("https://t.me/SomeBot"))

        XCTAssertEqual(result, .openChat(chat))
    }

    func testExternalUrlButtonOpensLink() async throws {
        let result = await press(.url("https://example.com/page?a=1"))

        XCTAssertEqual(result, try .openLink(XCTUnwrap(URL(string: "https://example.com/page?a=1"))))
    }

    func testLoginUrlButtonFallsBackToPlainLink() async throws {
        let result = await press(.loginUrl("https://example.com/login"))

        XCTAssertEqual(result, try .openLink(XCTUnwrap(URL(string: "https://example.com/login"))))
    }

    func testInvalidUrlButtonGivesInvalidLinkNotice() async {
        let empty = await press(.url(""))
        let garbage = await press(.url("not a link"))

        XCTAssertEqual(empty, .notice(L10n.string("Invalid link")))
        XCTAssertEqual(garbage, .notice(L10n.string("Invalid link")))
    }

    func testUnsupportedTelegramUrlGivesNotAvailableNotice() async {
        let invite = await press(.url("https://t.me/joinchat/AAAAAEabc"))
        let stickers = await press(.url("https://t.me/addstickers/Pack"))

        XCTAssertEqual(invite, .notice(notAvailable))
        XCTAssertEqual(stickers, .notice(notAvailable))
    }

    func testTelegramUrlToUnknownUsernameShowsErrorAndReturnsDone() async {
        let result = await press(.url("https://t.me/nosuchbot"))

        XCTAssertEqual(result, .done)
        XCTAssertNotNil(errorPresenter.error)
    }

    func testTelegramUrlLookupFailureShowsServiceError() async {
        service.publicChatError = TestError.failed("Resolve failed")

        let result = await press(.url("https://t.me/somebot"))

        XCTAssertEqual(result, .done)
        XCTAssertEqual(errorPresenter.error, "Resolve failed")
    }

    func testTelegramUrlLookupCancellationIsSilent() async {
        service.publicChatError = CancellationError()

        let result = await press(.url("https://t.me/somebot"))

        XCTAssertEqual(result, .done)
        XCTAssertNil(errorPresenter.error)
    }

    // MARK: - User buttons

    func testUserButtonOpensKnownContact() async {
        let contact = ContactInfo(
            id: 77, firstName: "Ann", lastName: "Lee", phone: "", username: "ann",
            photoFileId: nil, isOnline: false, lastSeen: nil
        )
        service.contacts = [contact]

        let result = await press(.user(userId: 77))

        XCTAssertEqual(result, .openContact(contact))
    }

    func testUserButtonOpensContactResolvedByTheService() async {
        let result = await press(.user(userId: 4242))

        guard case .openContact(let contact) = result else {
            return XCTFail("expected .openContact, got \(result)")
        }
        XCTAssertEqual(contact.id, 4242)
    }

    func testUserButtonFailureShowsErrorAndReturnsDone() async {
        service.contactsError = TestError.failed("User unavailable")

        let result = await press(.user(userId: 77))

        XCTAssertEqual(result, .done)
        XCTAssertEqual(errorPresenter.error, "User unavailable")
    }

    // MARK: - Copy text

    func testCopyTextButtonShowsTheTextInAnAlert() async {
        let result = await press(.copyText("PROMO-2024"))

        XCTAssertEqual(result, .alert("PROMO-2024"))
    }

    func testEmptyCopyTextButtonIsDone() async {
        let result = await press(.copyText(""))

        XCTAssertEqual(result, .done)
    }

    // MARK: - Unsupported buttons

    func testUnsupportedButtonKindsGiveNotAvailableNoticeWithoutNetworkCalls() async {
        let actions: [InlineKeyboardButton.Action] = [
            .webApp("https://app.example.com"),
            .buy,
            .callbackGame,
            .switchInline(query: "cats"),
            .callbackWithPassword,
            .unsupported("inlineKeyboardButtonTypeFuture")
        ]

        for action in actions {
            let result = await press(action)

            XCTAssertEqual(result, .notice(notAvailable), "\(action)")
        }
        XCTAssertTrue(service.callbackQueries.isEmpty)
        XCTAssertNil(errorPresenter.error)
    }

    // MARK: - Share phone number

    func testSharePhoneNumberSuccessRecordsChatAndReturnsTrue() async {
        let shared = await manager.sharePhoneNumber(chatId: 9)

        XCTAssertTrue(shared)
        XCTAssertEqual(service.sharedPhoneNumberChats, [9])
        XCTAssertNil(errorPresenter.error)
    }

    func testSharePhoneNumberFailureShowsErrorAndReturnsFalse() async {
        service.sharePhoneNumberError = TestError.failed("No phone")

        let shared = await manager.sharePhoneNumber(chatId: 9)

        XCTAssertFalse(shared)
        XCTAssertTrue(service.sharedPhoneNumberChats.isEmpty)
        XCTAssertEqual(errorPresenter.error, "No phone")
    }

    func testSharePhoneNumberBotInteractionErrorUsesLocalizedDescription() async {
        service.sharePhoneNumberError = BotInteractionError.unsupported

        let shared = await manager.sharePhoneNumber(chatId: 9)

        XCTAssertFalse(shared)
        XCTAssertEqual(errorPresenter.error, L10n.string("Not available on Apple Watch"))
    }

    func testSharePhoneNumberCancellationIsSilent() async {
        service.sharePhoneNumberError = CancellationError()

        let shared = await manager.sharePhoneNumber(chatId: 9)

        XCTAssertFalse(shared)
        XCTAssertNil(errorPresenter.error)
    }
}
