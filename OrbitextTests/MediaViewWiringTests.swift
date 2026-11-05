import SwiftUI
import XCTest
@testable import OrbitextWatch

/// Which files the media views of a chat ask the transport for, and when.
/// Each view is rendered with ImageRenderer over an ImageCache that records
/// the requests, as far as a render goes: no touch, no scroll.
@MainActor
final class MediaViewWiringTests: XCTestCase {
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
    }

    override func tearDown() async throws {
        app.eventTask?.cancel()
        app.resetSyncPipeline()
        app = nil
        try await super.tearDown()
    }

    func testPhotoTileDownloadsThePreviewNotTheFullSizeFile() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(
            PhotoThumbnailView(fileId: "100", width: 1280, height: 960, previewFileId: "50"),
            cache: cache
        )

        try await waitUntil { files.started.contains("50") }
        _ = renderer

        XCTAssertEqual(files.started, ["50"], "The viewer is the only reader of the full-size file")
    }

    func testPhotoWithoutAPreviewDownloadsItsOnlyFile() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(PhotoThumbnailView(fileId: "100", width: 200, height: 150), cache: cache)

        try await waitUntil { files.started.contains("100") }
        _ = renderer

        XCTAssertEqual(files.started, ["100"])
    }

    func testPhotoViewerOpensTheFullSizeFileAtTheRequestedPriorityAndShowsThePreviewFirst() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(MediaViewer(fileId: "100", mode: .photo, previewFileId: "50"), cache: cache)

        try await waitUntil { files.started.contains("100") && files.started.contains("50") }
        _ = renderer

        XCTAssertEqual(files.priority(of: "100")?.value, .requested, "The user asked for this photo")
        XCTAssertEqual(Set(files.started), ["50", "100"])
    }

    /// An album gallery builds a viewer for every photo at once.
    func testGalleryPageOffScreenRequestsNothingUntilItIsSwipedTo() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(MediaViewer(fileId: "100", mode: .photo, isActive: false, previewFileId: "50"), cache: cache)

        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        _ = renderer

        XCTAssertEqual(files.started, [], "Neither its preview nor its photo may queue behind the page on screen")
    }

    func testGalleryDownloadsOnlyThePageOnScreen() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let album = MessageAlbumInfo(albumId: 1, messages: (1...6).map {
            photoMessage(id: Int64($0), fileId: "\($0)00", previewFileId: "\($0)0")
        })
        let renderer = render(AlbumGalleryView(album: album, startIndex: 1), cache: cache)

        try await waitUntil { files.started.contains("200") && files.started.contains("20") }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        _ = renderer

        XCTAssertEqual(Set(files.started), ["20", "200"], "The pages nobody sees ask for nothing, previews included")
    }

    /// Paging is the task being keyed on whether the page is on screen: the
    /// page swiped to starts, the page swiped away stops.
    func testGalleryPageLoadsWhenSwipedToAndStopsWhenSwipedAway() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let page = PageState()
        let renderer = render(PageHost(page: page), cache: cache)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.started, [], "Not the page on screen yet")

        page.isActive = true
        await redraw(renderer)
        try await waitUntil { Set(files.started) == ["50", "100"] }
        XCTAssertEqual(files.priority(of: "100")?.value, .requested, "The user swiped to this photo")

        page.isActive = false
        await redraw(renderer)
        try await waitUntil { Set(files.cancelled) == ["50", "100"] }

        page.isActive = true
        await redraw(renderer)
        try await waitUntil { files.started.count == 4 }
    }

    /// A photo the page already shows is not read and decoded again each time
    /// the user pages back to it.
    func testGalleryPageDrawnOnceIsNotLoadedAgainWhenPagedBackTo() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let page = PageState()
        page.isActive = true
        let renderer = render(PageHost(page: page), cache: cache)
        try await waitUntil { files.started.contains("100") }
        let spinner = pixels(renderer)
        files.release()
        try await waitForPixels(of: renderer, toDifferFrom: spinner)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.started.filter { $0 == "100" }.count, 1)

        page.isActive = false
        await redraw(renderer)
        page.isActive = true
        await redraw(renderer)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(files.started.filter { $0 == "100" }.count, 1, "The page had its photo already")
    }

    // MARK: - Pages far from the selected one

    /// A gallery builds a viewer for every photo and keeps the bitmap of each
    /// page shown: ten HD photos are 200 MB, and the app is killed at 181 MB.
    func testGalleryKeepsThePhotosOfTheSelectedPageAndItsNeighboursOnly() {
        func kept(selection: Int) -> [Int] {
            (0..<6).filter { AlbumGalleryPages.keepsPhoto(at: $0, selection: selection) }
        }

        XCTAssertEqual(kept(selection: 0), [0, 1])
        XCTAssertEqual(kept(selection: 2), [1, 2, 3])
        XCTAssertEqual(kept(selection: 5), [4, 5])
    }

    func testGalleryPageFarFromTheSelectionLetsGoOfItsPhoto() async throws {
        let files = RecordingFiles()
        files.release()
        let made = MadeImages()
        let cache = ImageCache(service: files, thumbnailDecoder: made.decoder)
        let page = PageState()
        page.isActive = true
        let renderer = render(PageHost(page: page), cache: cache)
        try await waitUntil { made.viewerPhotosAlive == 1 }
        try await settle(renderer)
        XCTAssertEqual(made.viewerPhotosAlive, 1, "The page on screen holds its photo")

        page.isActive = false
        try await settle(renderer)
        XCTAssertEqual(made.viewerPhotosAlive, 1, "A neighbour of the selected page keeps its photo ready for the swipe")

        page.keepsImage = false
        try await settle(renderer)
        XCTAssertEqual(made.viewerPhotosAlive, 0, "A page two away holds no bitmap")
    }

    /// A page seen and let go is not a page never opened: dragged in from the
    /// side, it still draws the small preview, not a bare spinner.
    func testGalleryPageThatLetGoOfItsPhotoStillDrawsItsPreview() async throws {
        let files = RecordingFiles()
        files.release()
        let made = MadeImages()
        let cache = ImageCache(service: files, thumbnailDecoder: made.decoder)

        let neverOpened = PageState()
        let blank = render(PageHost(page: neverOpened), cache: cache)
        try await settle(blank)
        let bare = pixels(blank)

        let page = PageState()
        page.isActive = true
        let renderer = render(PageHost(page: page), cache: cache)
        try await waitUntil { made.viewerPhotosAlive == 1 }
        try await settle(renderer)

        page.isActive = false
        page.keepsImage = false
        try await settle(renderer)

        XCTAssertEqual(made.viewerPhotosAlive, 0, "The photo is let go")
        XCTAssertNotEqual(pixels(renderer), bare, "The preview stays, so the page is not an empty canvas")
    }

    func testGalleryPageThatLetGoOfItsPhotoLoadsItAgainWhenPagedBackTo() async throws {
        let files = RecordingFiles()
        files.release()
        let made = MadeImages()
        let cache = ImageCache(service: files, thumbnailDecoder: made.decoder)
        let page = PageState()
        page.isActive = true
        let renderer = render(PageHost(page: page), cache: cache)
        try await waitUntil { made.viewerPhotosMade == 1 }
        page.isActive = false
        page.keepsImage = false
        try await settle(renderer)

        page.isActive = true
        page.keepsImage = true
        await redraw(renderer)

        try await waitUntil { made.viewerPhotosMade == 2 }
        try await settle(renderer)
        XCTAssertEqual(files.started.filter { $0 == "100" }.count, 2, "The file is read again, from TDLib's copy")
        XCTAssertEqual(made.viewerPhotosAlive, 1)
    }

    /// The pages follow the selection: the photos of every page paged past
    /// are not all there when the gallery has been through the album.
    func testGalleryHoldsThePhotosOfTwoPagesAtMostWhilePagingForward() async throws {
        let files = RecordingFiles()
        files.release()
        let made = MadeImages()
        let cache = ImageCache(service: files, thumbnailDecoder: made.decoder)
        let position = GalleryPosition()
        let renderer = render(GalleryPagesHost(album: fivePhotoAlbum(), position: position), cache: cache)

        for page in 0..<5 {
            try await show(page: page, in: position, renderer: renderer, made: made)
            XCTAssertEqual(made.viewerPhotosAlive, min(page + 1, 2), "The page shown and the page before it, at page \(page)")
        }
    }

    /// Paging back costs a load for the page that was let go, not for a
    /// neighbour that kept its photo.
    func testGalleryLoadsAgainOnlyThePagesThatLetGo() async throws {
        let files = RecordingFiles()
        files.release()
        let made = MadeImages()
        let cache = ImageCache(service: files, thumbnailDecoder: made.decoder)
        let position = GalleryPosition()
        let renderer = render(GalleryPagesHost(album: fivePhotoAlbum(), position: position), cache: cache)
        for page in 0..<5 {
            try await show(page: page, in: position, renderer: renderer, made: made)
        }

        position.selection = 3
        try await settle(renderer)
        XCTAssertEqual(files.started.filter { $0 == "400" }.count, 1, "Page 3 was next to page 4: its photo stayed")

        position.selection = 2
        await redraw(renderer)
        try await waitUntil { files.started.filter { $0 == "300" }.count == 2 }
        try await settle(renderer)
        XCTAssertEqual(files.started.filter { $0 == "400" }.count, 1)
        XCTAssertEqual(made.viewerPhotosAlive, 2, "Pages 2 and 3; page 4 is two away now")
    }

    func testAlbumMosaicDownloadsThePreviewOfEveryCell() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let album = MessageAlbumInfo(albumId: 1, messages: [
            photoMessage(id: 1, fileId: "100", previewFileId: "50"),
            photoMessage(id: 2, fileId: "200", previewFileId: "60"),
            photoMessage(id: 3, fileId: "300", previewFileId: nil)
        ])
        let renderer = render(AlbumView(album: album, isGroup: false, availableWidth: 184), cache: cache)

        try await waitUntil { Set(files.started) == ["50", "60", "300"] }
        _ = renderer

        XCTAssertEqual(Set(files.started), ["50", "60", "300"], "A cell without a preview draws its only file")
    }

    // MARK: - Rows outside the viewport

    /// A chat builds every row of its window, so a row's media loads while the
    /// row is on screen: it starts when the row comes in and stops when it goes.
    func testPhotoOfARowOutsideTheViewportDownloadsNothingUntilItComesIn() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let row = RowVisibility()
        let renderer = render(
            VisibilityHost(row: row, content: PhotoThumbnailView(fileId: "100", width: 1280, height: 960, previewFileId: "50")),
            cache: cache
        )
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.started, [], "Nobody can see it")

        row.isOnScreen = true
        await redraw(renderer)
        try await waitUntil { files.started == ["50"] }

        row.isOnScreen = false
        await redraw(renderer)
        try await waitUntil { files.cancelled == ["50"] }

        row.isOnScreen = true
        await redraw(renderer)
        try await waitUntil { files.started == ["50", "50"] }
    }

    func testEveryKindOfChatMediaWaitsForItsRowToComeIn() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let row = RowVisibility()
        let renderers = everyKindOfChatMedia().map { render(VisibilityHost(row: row, content: $0), cache: cache) }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.started, [], "Not one of them may start a download for a row nobody sees")

        row.isOnScreen = true
        for renderer in renderers { await redraw(renderer) }

        try await waitUntil { Set(files.started) == Self.filesOfEveryKindOfChatMedia }
    }

    /// A row that scrolls away ends the downloads of all its media, not only
    /// the photo's.
    func testEveryKindOfChatMediaStopsWhenItsRowLeaves() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let row = RowVisibility()
        row.isOnScreen = true
        let renderers = everyKindOfChatMedia().map { render(VisibilityHost(row: row, content: $0), cache: cache) }
        try await waitUntil { Set(files.started) == Self.filesOfEveryKindOfChatMedia }

        row.isOnScreen = false
        for renderer in renderers { await redraw(renderer) }

        try await waitUntil { Set(files.cancelled) == Self.filesOfEveryKindOfChatMedia }
    }

    func testPhotoTileKeepsItsPictureWhileItsRowIsAway() async throws {
        try await assertPictureSurvivesItsRowLeaving(PhotoThumbnailView(fileId: "100", width: 1280, height: 960, previewFileId: "50"))
    }

    func testVideoPosterKeepsItsPictureWhileItsRowIsAway() async throws {
        try await assertPictureSurvivesItsRowLeaving(
            VideoThumbnailView(fileId: "2", thumbnailId: "3", width: 100, height: 100, duration: 4, style: .video)
        )
    }

    func testStickerKeepsItsPictureWhileItsRowIsAway() async throws {
        try await assertPictureSurvivesItsRowLeaving(StickerView(emoji: "x", fileId: "4", thumbnailFileId: "5"))
    }

    func testAlbumCellKeepsItsPictureWhileItsRowIsAway() async throws {
        try await assertPictureSurvivesItsRowLeaving(TDLibImage(fileId: "6"))
    }

    /// The window a chat row sits in reports the row to be on screen once the
    /// scroll view lays it out, and the media starts.
    func testRowInATimelineWindowLoadsOnceItIsLaidOut() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(
            TimelineRowWindow(value: 0) {
                PhotoThumbnailView(fileId: "100", width: 1280, height: 960, previewFileId: "50")
            },
            cache: cache
        )

        try await waitUntil { files.started == ["50"] }
        _ = renderer
    }

    // MARK: - Voice and audio

    /// A voice message in a chat may never be played, and an audio file is
    /// megabytes: nothing downloads until the user plays it.
    func testVoiceMessageDownloadsNothingUntilItIsPlayed() async throws {
        let files = RecordingFiles()
        let host = VoiceHost(files: files)

        host.render()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.started, [], "Nobody asked to hear it")

        host.tap()
        try await waitUntil { files.started == ["9"] }
        XCTAssertEqual(files.priority(of: "9")?.value, .requested, "The user waits for this one")
    }

    /// Audio files are whole tracks that used to come down at once when their row appeared.
    func testAudioFileIsNotDownloadedWhenItsRowAppears() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let renderer = render(
            MessageContentView(content: .audio(title: "Song", performer: "Band", duration: 200, fileId: "77"), isOutgoing: false),
            cache: cache
        )

        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        _ = renderer

        XCTAssertEqual(files.started, [])
    }

    func testVoiceMessageThatArrivesAfterTheTapPlaysByItself() async throws {
        let files = RecordingFiles(payload: VoiceManagerTests.silentWAV())
        let host = VoiceHost(files: files)
        host.render()

        host.tap()
        try await waitUntil { files.started == ["9"] }
        XCTAssertFalse(host.voiceManager.isPlaying(fileId: "9"))
        files.release()

        try await waitUntil { host.voiceManager.isPlaying(fileId: "9") }
        host.voiceManager.stop()
    }

    func testVoiceMessageTheTransportAlreadyHoldsPlaysWithoutADownload() async throws {
        let url = try Self.heldVoiceFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let files = RecordingFiles()
        files.hold(fileId: "9", at: url)
        let host = VoiceHost(files: files)
        host.render()
        // The file is picked up from the transport in the background.
        try await waitUntil { files.finishedLookups == 1 }

        host.tap()

        try await waitUntil { host.voiceManager.isPlaying(fileId: "9") }
        XCTAssertEqual(files.started, [], "It was on the device already")
        host.voiceManager.stop()
    }

    /// The tap can come before the transport has said whether it holds the
    /// file, as when the user taps a message they sent the moment the chat
    /// opens. The file is still not downloaded.
    func testTapBeforeTheTransportAnswersPlaysTheFileItHolds() async throws {
        let url = try Self.heldVoiceFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let files = RecordingFiles()
        files.hold(fileId: "9", at: url)
        files.pauseLookups()
        let host = VoiceHost(files: files)
        host.render()
        try await waitUntil { files.lookups == 1 }

        host.tap()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(files.started, [], "The answer is not in yet")
        files.resumeLookups()

        try await waitUntil { host.voiceManager.isPlaying(fileId: "9") }
        XCTAssertEqual(files.started, [], "It was on the device already")
        host.voiceManager.stop()
    }

    func testTapBeforeTheTransportAnswersDownloadsWhenItHoldsNothing() async throws {
        let files = RecordingFiles()
        files.pauseLookups()
        let host = VoiceHost(files: files)
        host.render()
        try await waitUntil { files.lookups == 1 }

        host.tap()
        files.resumeLookups()

        try await waitUntil { files.started == ["9"] }
        XCTAssertEqual(files.priority(of: "9")?.value, .requested, "The user waits for this one")
    }

    private static func heldVoiceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString).wav")
        try VoiceManagerTests.silentWAV().write(to: url)
        return url
    }

    // MARK: - Helpers

    /// What a chat row can hold, one of each, and the files they ask for.
    private func everyKindOfChatMedia() -> [AnyView] {
        let album = MessageAlbumInfo(albumId: 1, messages: [
            photoMessage(id: 1, fileId: "100", previewFileId: "50"),
            photoMessage(id: 2, fileId: "200", previewFileId: "60")
        ])
        return [
            AnyView(PhotoThumbnailView(fileId: "1", width: 100, height: 100)),
            AnyView(VideoThumbnailView(fileId: "2", thumbnailId: "3", width: 100, height: 100, duration: 4, style: .video)),
            AnyView(StickerView(emoji: "x", fileId: "4", thumbnailFileId: "5")),
            AnyView(TDLibImage(fileId: "6")),
            AnyView(AlbumView(album: album, isGroup: false, availableWidth: 184))
        ]
    }

    private static let filesOfEveryKindOfChatMedia: Set = ["1", "3", "5", "6", "50", "60"]

    /// Draws the view with its row on screen until the picture is there, then
    /// takes the row away and brings it back. The picture is the same all
    /// along: it does not flash the placeholder, and it needs no new download.
    private func assertPictureSurvivesItsRowLeaving(_ content: some View, line: UInt = #line) async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let row = RowVisibility()
        row.isOnScreen = true
        let renderer = render(VisibilityHost(row: row, content: content), cache: cache)
        try await waitUntil { !files.started.isEmpty }
        let placeholder = pixels(renderer)

        files.release()
        try await waitForPixels(of: renderer, toDifferFrom: placeholder)
        try await Task.sleep(for: .milliseconds(100))
        let drawn = pixels(renderer)
        let downloads = files.started.count

        row.isOnScreen = false
        await redraw(renderer)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pixels(renderer), drawn, "The picture stays while its row is away", line: line)

        row.isOnScreen = true
        await redraw(renderer)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pixels(renderer), drawn, "The picture is there when its row comes back", line: line)
        XCTAssertEqual(files.started.count, downloads, "It needs no new download", line: line)
    }

    private func render(_ view: some View, cache: ImageCache) -> ImageRenderer<some View> {
        let renderer = ImageRenderer(content: view.environment(cache).injectingAppState(app).frame(width: 184, height: 224))
        renderer.scale = 1
        _ = renderer.cgImage
        return renderer
    }

    private func redraw(_ renderer: ImageRenderer<some View>) async {
        for _ in 0..<5 {
            await Task.yield()
            _ = renderer.cgImage
        }
    }

    private func fivePhotoAlbum() -> MessageAlbumInfo {
        MessageAlbumInfo(albumId: 1, messages: (1...5).map {
            photoMessage(id: Int64($0), fileId: "\($0)00", previewFileId: "\($0)0")
        })
    }

    /// Moves the gallery to a page it has not shown, and waits until the page
    /// has its photo.
    private func show(
        page: Int,
        in position: GalleryPosition,
        renderer: ImageRenderer<some View>,
        made: MadeImages
    ) async throws {
        let before = made.viewerPhotosMade
        position.selection = page
        await redraw(renderer)
        try await waitUntil { made.viewerPhotosMade > before }
        try await settle(renderer)
    }

    /// Draws until the view has caught up with the state, and a little longer
    /// for what it lets go of to be released.
    private func settle(_ renderer: ImageRenderer<some View>) async throws {
        await redraw(renderer)
        try await Task.sleep(for: .milliseconds(150))
        await redraw(renderer)
    }

    private func photoMessage(id: Int64, fileId: String, previewFileId: String?) -> MessageInfo {
        MessageInfo(
            id: id, chatId: 1, senderName: "Alice", senderId: 2,
            content: .photo(caption: "", fileId: fileId, width: 1280, height: 960, minithumbnail: nil, previewFileId: previewFileId),
            date: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: false, isRead: false, mediaAlbumId: 1
        )
    }

    private func pixels(_ renderer: ImageRenderer<some View>) -> Data? {
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    /// The renderer redraws only when asked to, so a wait for the picture
    /// to change has to ask on every turn.
    private func waitForPixels(of renderer: ImageRenderer<some View>, toDifferFrom before: Data?, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while pixels(renderer) == before {
            guard ContinuousClock.now < deadline else { return XCTFail("The picture never changed") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A voice message row, tapped by raising `playbackRequest` the way the
/// message bubble does.
@MainActor
private final class VoiceHost {
    var voiceManager: VoiceManager { app.voiceManager }
    private let taps = TapCounter()
    private let app: AppState
    private let cache: ImageCache
    private var renderer: ImageRenderer<AnyView>?

    init(files: RecordingFiles) {
        app = AppState(
            service: MockTelegramService(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        cache = ImageCache(service: files)
    }

    func render() {
        let taps = taps
        let content = AnyView(
            VoiceRow(taps: taps)
                .environment(cache)
                .injectingAppState(app)
                .frame(width: 184, height: 60)
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        _ = renderer.cgImage
        self.renderer = renderer
    }

    func tap() {
        taps.count += 1
        for _ in 0..<5 { _ = renderer?.cgImage }
    }
}

@MainActor
@Observable
private final class TapCounter {
    var count = 0
}

private struct VoiceRow: View {
    let taps: TapCounter

    var body: some View {
        VoicePlayerView(fileId: "9", duration: 5, playbackRequest: taps.count)
    }
}

/// Whether an album gallery page is the one on screen.
@MainActor
@Observable
private final class PageState {
    var isActive = false
    /// A neighbour of the selected page keeps its photo; one further away does not.
    var keepsImage = true
}

private struct PageHost: View {
    let page: PageState

    var body: some View {
        MediaViewer(fileId: "100", mode: .photo, isActive: page.isActive, keepsImage: page.keepsImage, previewFileId: "50")
    }
}

/// The page of an album gallery that is selected.
@MainActor
@Observable
private final class GalleryPosition {
    var selection = 0
}

private struct GalleryPagesHost: View {
    let album: MessageAlbumInfo
    let position: GalleryPosition

    var body: some View {
        AlbumGalleryPages(thumbnails: album.thumbnails, selection: position.selection, pageSize: CGSize(width: 184, height: 224))
    }
}

/// The decoder of an ImageCache that makes a new image on every call, and
/// remembers each of them weakly to tell which are still alive.
@MainActor
private final class MadeImages {
    private struct Made {
        let maxPixels: Int
        weak var image: UIImage?
    }

    private var made: [Made] = []

    var decoder: ImageCache.ThumbnailDecoder {
        { [self] _, maxPixels in await make(maxPixels: maxPixels) }
    }

    /// The photos the viewer decoded, and how many of them anything still holds.
    var viewerPhotosMade: Int { viewerPhotos.count }
    var viewerPhotosAlive: Int { viewerPhotos.filter { $0.image != nil }.count }

    private var viewerPhotos: [Made] {
        made.filter { $0.maxPixels == AppConstants.UI.Viewer.maxPixelSize }
    }

    private func make(maxPixels: Int) -> UIImage {
        let image = UIImage(data: RecordingFiles.imageData()) ?? UIImage()
        made.append(Made(maxPixels: maxPixels, image: image))
        return image
    }
}

/// Whether a row is on screen, which a chat row's modifier would report.
@MainActor
@Observable
private final class RowVisibility {
    var isOnScreen = false
}

private struct VisibilityHost<Content: View>: View {
    let row: RowVisibility
    let content: Content

    var body: some View {
        content.environment(\.isMediaWanted, row.isOnScreen)
    }
}
