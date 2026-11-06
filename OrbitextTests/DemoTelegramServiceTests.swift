#if DEBUG
import XCTest
@testable import OrbitextWatch

/// Demo mode is a Debug-only transport over invented data: it must serve the
/// screens a screenshot needs and take its launch arguments exactly.
final class DemoTelegramServiceTests: XCTestCase {
    private var service: DemoTelegramService!

    override func setUp() {
        service = DemoTelegramService()
    }

    // MARK: - Chat list

    func testChatPageHasPinnedMutedUnreadAndDraftChats() async throws {
        let page = try await service.getChatPage(limit: 20, folderId: nil)

        XCTAssertEqual(page.chats.count, 8)
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(page.chats.filter(\.isPinned).map(\.title), ["Alex Morgan", "Saved Messages"])
        XCTAssertEqual(page.chats.filter(\.isMuted).map(\.title), ["Orbitext News"])
        XCTAssertTrue(page.chats.contains { $0.isChannel })
        XCTAssertTrue(page.chats.contains { $0.isGroup })
        XCTAssertTrue(page.chats.contains { $0.unreadCount > 0 })
        XCTAssertTrue(page.chats.contains { $0.hasDraft })
        XCTAssertEqual(page.chats.map(\.order), page.chats.map(\.order).sorted(by: >))
    }

    func testSavedMessagesIsTheCurrentUsersOwnChat() async throws {
        let savedChats = try await service.getChats(limit: 20, folderId: nil).filter { service.isSelfChat(chatId: $0.id) }

        XCTAssertEqual(savedChats.map(\.title), ["Saved Messages"])
    }

    func testFolderPageHoldsOnlyItsChats() async throws {
        let groups = try await service.getChatPage(limit: 20, folderId: DemoContent.groupsFolderId)

        XCTAssertEqual(Set(groups.chats.map(\.id)), [DemoContent.hikeChatId, DemoContent.newsChatId])
        let folders = try await service.getChatFolders()
        XCTAssertEqual(folders.map(\.title), ["Personal", "Groups"])
    }

    // MARK: - Conversation

    func testAlexConversationShowsEveryKindOfBubble() async throws {
        let newestFirst = try await service.getMessages(chatId: DemoContent.alexId, fromMessageId: 0, limit: 50)
        let thread = Array(newestFirst.reversed())

        XCTAssertEqual(thread.count, 10)
        XCTAssertTrue(thread.contains { $0.isOutgoing } && thread.contains { !$0.isOutgoing })
        XCTAssertTrue(thread.contains { if case .voice(_, _, let waveform) = $0.content { waveform?.isEmpty == false } else { false } })
        XCTAssertTrue(thread.contains { if case .photo = $0.content { true } else { false } })
        XCTAssertTrue(thread.contains { !$0.reactions.isEmpty })
        let reply = try XCTUnwrap(thread.first { $0.replyToMessageId != nil })
        XCTAssertEqual(reply.replyToPreview?.text, "Bring layers, it gets cold near the top.")
        XCTAssertTrue(thread.filter(\.isOutgoing).allSatisfy(\.isRead))
        XCTAssertEqual(Set(thread.map { Calendar.current.startOfDay(for: $0.date) }).count, 2, "yesterday and today")
    }

    func testOlderMessagesPageBackFromAnAnchor() async throws {
        let latest = try await service.getMessages(chatId: DemoContent.alexId, fromMessageId: 0, limit: 3)
        let older = try await service.getMessages(chatId: DemoContent.alexId, fromMessageId: latest[2].id, limit: 3)

        XCTAssertEqual(latest.map(\.id), [10, 9, 8])
        XCTAssertEqual(older.map(\.id), [7, 6, 5])
    }

    func testEveryChatOpensWithMessages() async throws {
        for chat in try await service.getChats(limit: 20, folderId: nil) {
            let messages = try await service.getMessages(chatId: chat.id, fromMessageId: 0, limit: 20)
            XCTAssertFalse(messages.isEmpty, chat.title)
            XCTAssertEqual(chat.lastMessage?.id, messages.first?.id, chat.title)
        }
    }

    // MARK: - Writes

    func testSendingAppendsAndAnnouncesTheMessage() async throws {
        var iterator = service.events.makeAsyncIterator()

        let sent = try await service.sendMessage(chatId: DemoContent.alexId, text: "On my way", replyToMessageId: 9)

        guard case .newMessage(let announced) = await iterator.next() else { return XCTFail("expected newMessage") }
        XCTAssertEqual(announced.id, sent.id)
        XCTAssertEqual(sent.id, 11)
        XCTAssertTrue(sent.isOutgoing)
        XCTAssertEqual(sent.replyToSenderName, "Alex Morgan")
        let chat = try await service.getChat(chatId: DemoContent.alexId)
        XCTAssertEqual(chat.lastMessage?.id, sent.id)
    }

    func testPinMuteAndReadChangeTheChatAndAnnounceIt() async throws {
        try await service.muteChat(chatId: DemoContent.priyaId, isMuted: true)
        try await service.pinChat(chatId: DemoContent.priyaId, isPinned: true)
        try await service.markAsRead(chatId: DemoContent.priyaId, messageId: 3)

        let chat = try await service.getChat(chatId: DemoContent.priyaId)
        XCTAssertTrue(chat.isMuted)
        XCTAssertTrue(chat.isPinned)
        XCTAssertEqual(chat.unreadCount, 0)
    }

    // MARK: - People and files

    func testContactsProfilesAndGroupInfo() async throws {
        let contacts = try await service.getContacts()
        let alex = try await service.getContact(userId: DemoContent.alexId)
        let hike = try await service.getGroupInfo(chatId: DemoContent.hikeChatId)

        XCTAssertEqual(contacts.count, 8)
        XCTAssertTrue(alex.isOnline)
        XCTAssertEqual(hike.memberCount, 4)
        XCTAssertTrue(contacts.allSatisfy { $0.phone.hasPrefix("+1 555 01") })
        let matches = try await service.searchContacts(query: "pri")
        XCTAssertEqual(matches.map(\.fullName), ["Priya Shah"])
    }

    func testPhotoVoiceAndStickersAreServedWithoutANetwork() async throws {
        let photo = try await service.downloadFile(fileId: DemoMedia.photoFileId)
        let voice = try await service.downloadFile(fileId: DemoMedia.voiceFileId)
        let stickers = try await service.getRecentStickers()

        XCTAssertNotNil(UIImage(data: photo), "the drawn photo decodes")
        XCTAssertEqual(String(decoding: voice.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertTrue(stickers.allSatisfy(\.isValid))
        do {
            _ = try await service.downloadFile(fileId: "unknown")
            XCTFail("an unknown file must fail")
        } catch {}
    }

    // MARK: - Sign-in

    func testStartupSelectsTheFirstAuthState() async {
        for (startup, expected) in [
            (DemoTelegramService.Startup.signedIn, AuthState.ready),
            (.signIn, .waitPhoneNumber),
            (.qrLogin, .waitOtherDeviceConfirmation),
        ] {
            let service = DemoTelegramService(startup: startup)
            var iterator = service.events.makeAsyncIterator()

            await service.start()

            guard case .authStateChanged(let state) = await iterator.next() else { return XCTFail("expected auth state") }
            XCTAssertEqual(state, expected)
        }
    }

    func testQRLoginOffersTheFakeToken() async {
        let service = DemoTelegramService(startup: .qrLogin)
        var iterator = service.events.makeAsyncIterator()

        await service.start()
        _ = await iterator.next()

        guard case .qrCodeLink(let link) = await iterator.next() else { return XCTFail("expected a QR link") }
        XCTAssertEqual(link, "tg://login?token=DEMO")
    }

    // MARK: - Launch arguments

    func testDemoModeStartsOnlyOnRequest() {
        XCTAssertNil(DemoLaunch(arguments: ["Orbitext"], environment: [:]))
        XCTAssertNil(DemoLaunch(arguments: ["Orbitext", "-OrbitextDemoScreen", "chat"], environment: [:]), "the screen alone is not a request")
        XCTAssertNotNil(DemoLaunch(arguments: ["Orbitext", "-OrbitextDemo"], environment: [:]))
        XCTAssertNotNil(DemoLaunch(arguments: ["Orbitext"], environment: ["ORBITEXT_DEMO": "1"]))
        XCTAssertNil(DemoLaunch(arguments: ["Orbitext"], environment: ["ORBITEXT_DEMO": "0"]))
    }

    func testLaunchArgumentsPickTheScreen() throws {
        let content = DemoContent()
        let chat = try XCTUnwrap(DemoLaunch(arguments: ["-OrbitextDemo", "-OrbitextDemoScreen", "chat"], environment: [:]))
        let qr = try XCTUnwrap(DemoLaunch(arguments: ["-OrbitextDemo", "-OrbitextDemoScreen", "signInQR"], environment: [:]))
        let fromEnvironment = try XCTUnwrap(DemoLaunch(arguments: [], environment: ["ORBITEXT_DEMO": "1", "ORBITEXT_DEMO_SCREEN": "settings"]))
        let unknown = try XCTUnwrap(DemoLaunch(arguments: ["-OrbitextDemo", "-OrbitextDemoScreen", "nope"], environment: [:]))
        let dangling = try XCTUnwrap(DemoLaunch(arguments: ["-OrbitextDemo", "-OrbitextDemoScreen"], environment: [:]))

        XCTAssertEqual(chat.route(in: content), [.chat(DemoContent.alexId)])
        XCTAssertEqual(qr.startup, .qrLogin)
        XCTAssertEqual(qr.route(in: content), [])
        XCTAssertEqual(fromEnvironment.route(in: content), [.settings])
        XCTAssertEqual(unknown.screen, .chatList)
        XCTAssertEqual(dangling.screen, .chatList)
    }

    func testOpenChatArgumentOverridesTheScreenRoute() throws {
        let launch = try XCTUnwrap(DemoLaunch(
            arguments: ["-OrbitextDemo", "-OrbitextDemoScreen", "settings", "-OrbitextDemoOpenChat", "1002"], environment: [:]
        ))

        XCTAssertEqual(launch.route(in: DemoContent()), [.chat(DemoContent.priyaId)])
    }

    func testEveryScreenHasARoute() {
        let content = DemoContent()
        for screen in DemoLaunch.Screen.allCases {
            let launch = DemoLaunch(arguments: ["-OrbitextDemo", "-OrbitextDemoScreen", screen.rawValue], environment: [:])
            XCTAssertEqual(launch?.screen, screen)
            let isSignIn = screen == .signIn || screen == .signInQR
            let isChatList = screen == .chatList
            XCTAssertEqual(launch?.route(in: content).isEmpty, isSignIn || isChatList, screen.rawValue)
        }
    }
}
#endif
