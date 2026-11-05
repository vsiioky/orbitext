import XCTest
@testable import OrbitextWatch

/// The requirements the protocol gives a default are the ones a forwarding
/// double silently loses when it forgets them: the compiler is satisfied
/// either way. Each is pushed through the base and read back from the mock.
@MainActor
final class ForwardingTelegramServiceTests: XCTestCase {
    func testDefaultedChatRequirementsReachTheMock() async throws {
        let service = ForwardingTelegramService()
        service.mock.chats = [ChatInfo(id: 1, title: "Chat", lastMessage: nil, unreadCount: 0,
                                       isGroup: false, isMuted: false, order: 1)]
        service.mock.getChatsPageIsComplete = true

        let page = try await service.getChatPage(limit: 10, folderId: nil)
        try await service.pinChat(chatId: 1, in: .folder(5), isPinned: true)

        XCTAssertTrue(page.isComplete, "The default page says a page is incomplete")
        XCTAssertEqual(service.mock.pinnedChats.map(\.list), [.folder(5)],
                       "The default pins in the Main list only")
    }

    func testDefaultedAttachmentAndBotRequirementsReachTheMock() async throws {
        let service = ForwardingTelegramService()
        service.mock.recentStickers = [StickerOption(fileId: "7", emoji: "x", thumbnailFileId: nil, width: 1, height: 1)]
        service.mock.callbackAnswer = BotCallbackAnswer(text: "answered")
        service.mock.botCommandsByChatId[3] = [BotCommandInfo(command: "start", description: "Start")]

        let stickers = try await service.getRecentStickers()
        _ = try await service.sendLocation(chatId: 3, location: SharedLocation(latitude: 1, longitude: 2, horizontalAccuracy: 3))
        let answer = try await service.getCallbackQueryAnswer(chatId: 3, messageId: 4, data: "d")
        let commands = try await service.getBotCommands(chatId: 3)

        XCTAssertEqual(stickers.map(\.fileId), ["7"])
        XCTAssertEqual(service.mock.sentLocations.map(\.chatId), [3])
        XCTAssertEqual(answer.text, "answered")
        XCTAssertEqual(commands.map(\.command), ["start"])
    }

    func testDefaultedStickerContactAndReplyMarkupRequirementsReachTheMock() async throws {
        let service = ForwardingTelegramService()
        let sticker = StickerOption(fileId: "7", emoji: "x", thumbnailFileId: nil, width: 1, height: 1)
        let markup = MessageInfo(id: 5, chatId: 3, senderName: "Bot", senderId: 99, content: .text("Menu"),
                                 date: Date(), isOutgoing: false, isRead: false, replyMarkup: nil)
        service.mock.replyMarkupMessagesByChatId[3] = markup

        _ = try await service.sendSticker(chatId: 3, sticker: sticker)
        _ = try await service.sharePhoneNumber(chatId: 4)
        let markupMessage = try await service.getReplyMarkupMessage(chatId: 3)

        XCTAssertEqual(service.mock.sentStickers.map(\.chatId), [3], "The default throws unsupported")
        XCTAssertEqual(service.mock.sharedPhoneNumberChats, [4], "The default throws unsupported")
        XCTAssertEqual(markupMessage?.id, 5, "The default throws unsupported")
    }

    func testFileAndDiagnosticsRequirementsReachTheMock() async throws {
        let service = ForwardingTelegramService()
        let file = URL(fileURLWithPath: "/tmp/forwarded.bin")
        service.mock.localFileURLs["9"] = file
        service.mock.cacheDirectories = [URL(fileURLWithPath: "/tmp/forwarded-db")]
        service.mock.floodWaitRemainingSeconds = 12
        service.mock.currentUserID = 77

        let url = try await service.localFileURL(fileId: "9")

        XCTAssertEqual(url, file)
        XCTAssertEqual(service.cacheDirectories.map(\.path), ["/tmp/forwarded-db"])
        XCTAssertEqual(service.currentFloodWaitRemaining(), 12)
        XCTAssertEqual(service.currentUserID, 77)
    }

    func testTelemetryReachesTheMock() {
        let service = ForwardingTelegramService()
        XCTAssertNil(service.telemetry)
        let telemetry = TDRequestTelemetry(ringCapacity: 1, burstThreshold: 1, burstWindow: 1)

        service.mock.telemetry = telemetry

        // `nil` would also satisfy the protocol's default.
        XCTAssertIdentical(service.telemetry, telemetry)
    }

    func testClientGenerationReachesTheMock() {
        let service = ForwardingTelegramService()
        XCTAssertEqual(service.clientGeneration, .initial)

        service.mock.clientGeneration = TDClientGeneration.initial.next()

        // `.initial` would also satisfy the protocol's default.
        XCTAssertEqual(service.clientGeneration.rawValue, 1)
    }

    func testSessionLifecycleReachesTheMock() async throws {
        let service = ForwardingTelegramService()

        await service.start()
        let retried = try await service.retryStartupIfNeeded()
        try await service.resetLocalSession()
        service.suspendForBackground()
        service.resumeFromBackground()

        XCTAssertFalse(retried)
        XCTAssertEqual(service.mock.startCallCount, 1)
        XCTAssertEqual(service.mock.retryStartupCallCount, 1)
        XCTAssertEqual(service.mock.resetLocalSessionCallCount, 1)
        XCTAssertEqual(service.mock.suspendCallCount, 1)
        XCTAssertEqual(service.mock.resumeCallCount, 1)
    }
}
