import SwiftUI
import XCTest
@testable import OrbitextWatch

/// The chat screen reads the history and the chat directory in small views of
/// their own, so a change to either redraws those, not the whole screen.
@MainActor
final class ChatScreenScopeTests: XCTestCase {
    private var apps: [AppState] = []

    override func tearDown() async throws {
        for app in apps {
            app.eventTask?.cancel()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        try await super.tearDown()
    }

    // MARK: - The history observer

    /// The modifier is the only reader of the history here: its content is a
    /// constant view that is never rebuilt, yet the handlers still hear of a
    /// change. That is what keeps the screen out of the history's way.
    func testHistoryObserverHearsChangesWithoutItsContentBeingRebuilt() async {
        let app = makeApp()
        app.chatMessageStore.reset(chatId: 42)
        let heard = HeardChanges()
        let renderer = ImageRenderer(content: Color.clear
            .frame(width: 100, height: 100)
            .modifier(ChatHistoryObserver(
                chatId: 42,
                onFirstMessageChanged: { heard.first += 1 },
                onLastMessageIdChanged: { heard.lastIds.append(Pair(old: $0, new: $1)) },
                onLastMessageChanged: { _, _ in heard.lastMessages += 1 },
                onPendingCountChanged: { heard.pending.append(Pair(old: Int64($0), new: Int64($1))) }
            ))
            .injectingAppState(app))
        renderer.scale = 1
        _ = renderer.cgImage

        app.chatMessageStore.handleIncomingMessage(message(id: 7))
        await redraw(renderer)

        XCTAssertEqual(heard.first, 1, "The first row went from none to 7")
        XCTAssertEqual(heard.lastIds, [Pair(old: nil, new: 7)])
        XCTAssertEqual(heard.lastMessages, 1)
    }

    // MARK: - Views that read for themselves

    /// The list is a constant here, built once. It draws the new row only
    /// because it reads the history itself, as the screen no longer hands it.
    func testMessageListRedrawsItselfWhenTheHistoryChanges() async throws {
        let app = makeApp()
        app.chatMessageStore.reset(chatId: 42)
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ChatMessageListView(
                chatId: 42,
                isGroup: false,
                availableWidth: 184,
                composeTarget: .constant(nil),
                forwardingMessage: .constant(nil),
                onLoadOlder: {}
            )
        }
        .frame(width: 184, height: 224, alignment: .top)
        .background(Color.black)
        .injectingAppState(app))
        renderer.scale = 1
        let empty = try XCTUnwrap(pixels(renderer))

        app.chatMessageStore.handleIncomingMessage(message(id: 7))
        await redraw(renderer)

        XCTAssertNotEqual(try XCTUnwrap(pixels(renderer)), empty, "The new message never appeared")
    }

    func testTypingFooterAppearsWhenSomeoneTypesInTheChat() async throws {
        let app = makeApp()
        announce(chat(id: 42, title: "Typing here"), in: app)
        let renderer = ImageRenderer(content: VStack(spacing: 0) { ChatTypingFooter(chatId: 42) }
            .frame(width: 184, height: 80, alignment: .top)
            .background(Color.black)
            .injectingAppState(app))
        renderer.scale = 1
        let quiet = try XCTUnwrap(pixels(renderer))

        app.chatRepository.handleChatAction(chatId: 42, names: ["Alice"], kind: .typing)
        await redraw(renderer)

        XCTAssertNotEqual(try XCTUnwrap(pixels(renderer)), quiet, "The typing row never appeared")
    }

    func testGroupFlagFollowsTheDirectory() async throws {
        let app = makeApp()
        let renderer = ImageRenderer(content: GroupFlagHost(chatId: 42).frame(width: 184, height: 60).injectingAppState(app))
        renderer.scale = 1
        let unknown = try XCTUnwrap(pixels(renderer))

        announce(chat(id: 42, title: "Friends", isGroup: true), in: app)
        await redraw(renderer)

        XCTAssertNotEqual(try XCTUnwrap(pixels(renderer)), unknown, "The flag stayed false after the chat was announced as a group")
    }

    func testBottomInsetLeavesRoomForTheComposerExceptInChannels() throws {
        let app = makeApp()
        announce(chat(id: 42, title: "Channel", isChannel: true), in: app)
        announce(chat(id: 43, title: "Chat"), in: app)

        let channel = try XCTUnwrap(insetPixels(chatId: 42, in: app))
        let ordinary = try XCTUnwrap(insetPixels(chatId: 43, in: app))

        XCTAssertNotEqual(channel, ordinary, "A channel has no composer to leave room for")
    }

    /// The inset above a marker: the marker sits lower the more room it leaves.
    private func insetPixels(chatId: Int64, in app: AppState) -> Data? {
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ChatBottomInset(chatId: chatId)
            Color.red.frame(height: 10)
        }
        .frame(width: 100, height: 100, alignment: .top)
        .background(Color.black)
        .injectingAppState(app))
        renderer.scale = 1
        return pixels(renderer)
    }

    // MARK: - Fallback chat

    func testChatFallsBackToTheRouteThenToABlankChat() {
        let app = makeApp()
        let carried = ChatInfo(id: 9, title: "Carried", lastMessage: nil, unreadCount: 0, isGroup: true, isMuted: false, order: 0)

        XCTAssertEqual(app.chatRepository.chat(id: 9, fallback: carried).title, "Carried")
        XCTAssertEqual(app.chatRepository.chat(id: 9, fallback: nil).title, "Chat")
        XCTAssertFalse(app.chatRepository.chat(id: 9, fallback: nil).isGroup)

        let announced = ChatInfo(id: 9, title: "Announced", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
        app.chatRepository.handleChatPositionUpdate(.init(chat: announced, positions: [], source: .newChat))
        XCTAssertEqual(app.chatRepository.chat(id: 9, fallback: carried).title, "Announced", "The directory wins once it has the chat")
    }

    // MARK: - Helpers

    private func pixels(_ renderer: ImageRenderer<some View>) -> Data? {
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    private func chat(id: Int64, title: String, isGroup: Bool = false, isChannel: Bool = false) -> ChatInfo {
        var chat = ChatInfo(id: id, title: title, lastMessage: nil, unreadCount: 0, isGroup: isGroup, isMuted: false, order: 0)
        chat.isChannel = isChannel
        return chat
    }

    private func announce(_ chat: ChatInfo, in app: AppState) {
        app.chatRepository.handleChatPositionUpdate(.init(chat: chat, positions: [], source: .newChat))
    }

    private func redraw(_ renderer: ImageRenderer<some View>) async {
        for _ in 0..<5 {
            await Task.yield()
            _ = renderer.cgImage
        }
    }

    private func message(id: Int64) -> MessageInfo {
        MessageInfo(
            id: id, chatId: 42, senderName: "Alice", senderId: 2, content: .text(FormattedString(text: "Message \(id)")),
            date: Date(timeIntervalSince1970: TimeInterval(id)), isOutgoing: false, isRead: false
        )
    }

    private func makeApp() -> AppState {
        let app = AppState(
            service: MockTelegramService(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        apps.append(app)
        return app
    }
}

private struct Pair: Equatable {
    let old: Int64?
    let new: Int64?
}

@MainActor
private final class HeardChanges {
    var first = 0
    var lastIds: [Pair] = []
    var lastMessages = 0
    var pending: [Pair] = []
}

/// Shows the flag `ChatGroupFlagReader` copies, the way the screen holds it.
private struct GroupFlagHost: View {
    let chatId: Int64
    @State private var isGroup = false

    var body: some View {
        Text(isGroup ? "A group chat with a long label" : "")
            .background { ChatGroupFlagReader(chatId: chatId, isGroup: $isGroup) }
    }
}
