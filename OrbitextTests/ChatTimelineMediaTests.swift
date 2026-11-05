import SwiftUI
import XCTest
@testable import OrbitextWatch

/// The rows of the chat timeline, in a real scroll view, load their media
/// only while they are inside it. The views below are the ones the chat
/// screen builds, so a row that stops wearing the visibility modifier is
/// seen here and nowhere else.
@MainActor
final class ChatTimelineMediaTests: XCTestCase {
    private static let chatId: Int64 = 42
    /// Taller than the viewport the tests render in.
    private static let beyondTheViewport: CGFloat = 800

    private var app: AppState!

    override func setUp() async throws {
        try await super.setUp()
        app = AppState(
            service: MockTelegramService(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        app.chatMessageStore.reset(chatId: Self.chatId)
    }

    override func tearDown() async throws {
        app.eventTask?.cancel()
        app.resetSyncPipeline()
        app = nil
        try await super.tearDown()
    }

    func testPhotoRowInsideTheViewportLoadsItsPreview() async throws {
        let files = RecordingFiles()
        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50"))

        let renderer = render(offset: 0, files: files)

        try await waitUntil { files.started == ["50"] }
        _ = renderer
    }

    func testPhotoRowBeyondTheViewportLoadsNothing() async throws {
        let files = RecordingFiles()
        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50"))

        let renderer = render(offset: Self.beyondTheViewport, files: files)

        try await settle(renderer)
        XCTAssertEqual(files.started, [], "Nobody can see the row")
    }

    func testAlbumRowInsideTheViewportLoadsItsCells() async throws {
        let files = RecordingFiles()
        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50", albumId: 7))
        app.chatMessageStore.handleIncomingMessage(photo(id: 2, fileId: "200", previewFileId: "60", albumId: 7))

        let renderer = render(offset: 0, files: files)

        try await waitUntil { Set(files.started) == ["50", "60"] }
        _ = renderer
    }

    func testAlbumRowBeyondTheViewportLoadsNothing() async throws {
        let files = RecordingFiles()
        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50", albumId: 7))
        app.chatMessageStore.handleIncomingMessage(photo(id: 2, fileId: "200", previewFileId: "60", albumId: 7))

        let renderer = render(offset: Self.beyondTheViewport, files: files)

        try await settle(renderer)
        XCTAssertEqual(files.started, [], "Nobody can see the album")
    }

    // MARK: - Rows that arrive while the chat is open

    func testPhotoThatArrivesInsideTheViewportLoads() async throws {
        let files = RecordingFiles()
        let renderer = render(offset: 0, files: files)
        try await settle(renderer)

        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50"))
        try await waitUntil(redrawing: renderer) { files.started == ["50"] }
    }

    /// The first photo of an album is a message row until the second arrives
    /// and the album row takes its place, with a new identity.
    func testAlbumThatTakesTheRowOfItsFirstPhotoLoads() async throws {
        let files = RecordingFiles()
        app.chatMessageStore.handleIncomingMessage(photo(id: 1, fileId: "100", previewFileId: "50", albumId: 7))
        let renderer = render(offset: 0, files: files)
        try await waitUntil { files.started == ["50"] }

        app.chatMessageStore.handleIncomingMessage(photo(id: 2, fileId: "200", previewFileId: "60", albumId: 7))
        try await waitUntil(redrawing: renderer) { files.started.contains("60") }
    }

    // MARK: - Helpers

    /// The renderer redraws only when asked to, so a wait for a change in the
    /// views has to ask on every turn.
    private func waitUntil(redrawing renderer: ImageRenderer<some View>, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            _ = renderer.cgImage
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The list below `offset` points of nothing, in a scroll view that shows
    /// its first 224 points.
    private func render(offset: CGFloat, files: RecordingFiles) -> ImageRenderer<some View> {
        let cache = ImageCache(service: files)
        let view = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: offset)
                ChatMessageListView(
                    chatId: Self.chatId,
                    isGroup: false,
                    availableWidth: 184,
                    composeTarget: .constant(nil),
                    forwardingMessage: .constant(nil),
                    onLoadOlder: {}
                )
            }
        }
        .frame(width: 184, height: 224)
        .environment(cache)
        .injectingAppState(app)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
        return renderer
    }

    /// Long enough for a row that was going to load to have asked.
    private func settle(_ renderer: ImageRenderer<some View>) async throws {
        for _ in 0..<20 {
            await Task.yield()
            _ = renderer.cgImage
        }
        try await Task.sleep(for: .milliseconds(200))
        _ = renderer.cgImage
    }

    private func photo(id: Int64, fileId: String, previewFileId: String?, albumId: Int64 = 0) -> MessageInfo {
        MessageInfo(
            id: id, chatId: Self.chatId, senderName: "Alice", senderId: 2,
            content: .photo(caption: "", fileId: fileId, width: 1280, height: 960, minithumbnail: nil, previewFileId: previewFileId),
            date: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(id)), isOutgoing: false, isRead: false, mediaAlbumId: albumId
        )
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
