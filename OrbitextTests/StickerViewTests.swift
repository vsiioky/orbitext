import SwiftUI
import XCTest
@testable import OrbitextWatch

/// A sticker in a chat row: the picture it shows until it is tapped, the
/// space it takes, and the frames of the animation a tap plays.
@MainActor
final class StickerViewTests: XCTestCase {
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

    // MARK: - The picture

    /// A thumbnail decoded by the row itself was drawn at the file's size,
    /// outside the cache's budget, and read and decoded again for every row
    /// the timeline drew again.
    func testThumbnailIsTheCachesPictureAtTheSizeTheStickerIsDrawn() async throws {
        let files = RecordingFiles(payload: RecordingFiles.imageData(width: 512, height: 512))
        files.release()
        let cache = ImageCache(service: files)
        let renderer = render(StickerView(emoji: "x", fileId: "4", thumbnailFileId: "5"), cache: cache)

        try await waitUntil("The cache never got the thumbnail") { cache.decodedImageBytes > 0 }
        let cached = await cache.load(fileId: "5", maxDimension: Self.drawnPixels)
        _ = renderer

        XCTAssertEqual(cached?.cgImage?.width, Int(Self.drawnPixels), "Bounded by the drawn size, not the file's 512 px")
        XCTAssertEqual(files.started, ["5"], "The picture came from the cache: no second read")
    }

    /// A static sticker sent without a thumbnail shows its own file, a WEBP
    /// of 512 px: 1 MB of bitmap for a slot 72 points wide.
    func testStickerWithoutAThumbnailShowsItsFileAtTheSizeItIsDrawn() async throws {
        let files = RecordingFiles(payload: RecordingFiles.imageData(width: 512, height: 512))
        files.release()
        let cache = ImageCache(service: files)
        let renderer = render(StickerView(emoji: "x", fileId: "4", thumbnailFileId: nil), cache: cache)

        try await waitUntil("The cache never got the sticker") { cache.decodedImageBytes > 0 }
        let cached = await cache.load(fileId: "4", maxDimension: Self.drawnPixels)
        _ = renderer

        XCTAssertEqual(cached?.cgImage?.width, Int(Self.drawnPixels))
        XCTAssertEqual(files.started, ["4"])
    }

    /// A timeline row released off screen keeps the height it measured, and
    /// is drawn again from scratch when it comes back: the emoji first, then
    /// the spinner, then the picture. A sticker that changed size on the way
    /// would move the rows below it on screen.
    func testStickerTakesTheSameSpaceWhateverItShows() async throws {
        let files = RecordingFiles(payload: RecordingFiles.imageData(width: 512, height: 256))
        let cache = ImageCache(service: files)
        let row = StickerRow()
        let renderer = render(StickerRowHost(row: row), cache: cache, rowWidthOnly: true)
        let beforeLoading = height(of: renderer)

        row.isOnScreen = true
        await redraw(renderer)
        try await waitUntil("The thumbnail never started") { files.started == ["5"] }
        let whileLoading = height(of: renderer)
        let spinner = pixels(of: renderer)

        files.release()
        try await waitUntil("The picture never came") { pixels(of: renderer) != spinner }
        let withPicture = height(of: renderer)

        let slot = AppConstants.UI.Sticker.size
        XCTAssertEqual(beforeLoading, slot, "The emoji, before the picture is wanted")
        XCTAssertEqual(whileLoading, slot, "The spinner")
        XCTAssertEqual(withPicture, slot, "A wide sticker's picture")
    }

    // MARK: - The animation

    /// A tap renders up to 75 frames of 64 px, each a bitmap with its own
    /// 16 KB buffer. They were kept after the animation ended, until the row
    /// was gone; a replay renders them again in tens of milliseconds.
    func testFramesGoWhenTheAnimationEnds() {
        let frames = MadeFrames(count: 45)
        var animation = StickerAnimation()
        animation.play(frames.take())

        for _ in 0..<44 {
            animation.advance()
        }
        XCTAssertTrue(animation.isPlaying, "One frame is left")
        animation.advance()

        XCTAssertFalse(animation.isPlaying)
        XCTAssertNil(animation.frame)
        XCTAssertEqual(frames.alive, 0, "Nothing holds the frames of an animation that ended")
    }

    func testFramesGoWhenTheAnimationIsStopped() {
        let frames = MadeFrames(count: 45)
        var animation = StickerAnimation()
        animation.play(frames.take())
        for _ in 0..<10 {
            animation.advance()
        }

        animation.stop()

        XCTAssertFalse(animation.isPlaying)
        XCTAssertEqual(frames.alive, 0)
    }

    func testAnimationShowsItsFramesInOrder() {
        let frames = MadeFrames(count: 3)
        let images = frames.take()
        var animation = StickerAnimation()

        animation.play(images)
        var shown = [animation.frame]
        animation.advance()
        shown.append(animation.frame)
        animation.advance()
        shown.append(animation.frame)

        XCTAssertTrue(zip(shown, images).allSatisfy { $0 === $1 })
    }

    // MARK: - Helpers

    private static var drawnPixels: CGFloat { AppConstants.UI.Sticker.size * scale }
    private static let scale: CGFloat = 2

    /// `rowWidthOnly` lays the view out the way a chat row does: as wide as
    /// the row, as tall as the view makes itself.
    private func render(_ view: some View, cache: ImageCache, rowWidthOnly: Bool = false) -> ImageRenderer<AnyView> {
        let content = view.environment(\.displayScale, Self.scale).environment(cache).injectingAppState(app)
        let renderer = ImageRenderer(content: rowWidthOnly
            ? AnyView(content.frame(width: 184))
            : AnyView(content.frame(width: 184, height: 224)))
        renderer.scale = 1
        _ = renderer.cgImage
        return renderer
    }

    /// The height the view lays itself out at, in points.
    private func height(of renderer: ImageRenderer<AnyView>) -> CGFloat? {
        renderer.cgImage.map { CGFloat($0.height) }
    }

    /// Asking for the pixels draws the view again.
    private func pixels(of renderer: ImageRenderer<AnyView>) -> Data? {
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    private func redraw(_ renderer: ImageRenderer<AnyView>) async {
        for _ in 0..<5 {
            await Task.yield()
            _ = renderer.cgImage
        }
    }

    private func waitUntil(_ message: String, timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Whether the sticker's row is on screen, as its timeline window reports it.
@MainActor
@Observable
private final class StickerRow {
    var isOnScreen = false
}

private struct StickerRowHost: View {
    let row: StickerRow

    var body: some View {
        StickerView(emoji: "x", fileId: "4", thumbnailFileId: "5")
            .environment(\.isMediaWanted, row.isOnScreen)
    }
}

/// Frames for an animation, remembered weakly to tell which are alive.
private final class MadeFrames {
    private struct Made {
        weak var image: UIImage?
    }

    private var made: [UIImage] = []
    private var weakFrames: [Made] = []

    init(count: Int) {
        let data = RecordingFiles.imageData()
        autoreleasepool {
            for _ in 0..<count {
                let image = UIImage(data: data) ?? UIImage()
                made.append(image)
                weakFrames.append(Made(image: image))
            }
        }
    }

    /// Hands the frames over; from here on only the caller holds them.
    func take() -> [UIImage] {
        defer { made = [] }
        return made
    }

    var alive: Int { weakFrames.filter { $0.image != nil }.count }
}
