import Dispatch
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import OrbitextWatch

/// What the app lets go of when it goes to the background or the system
/// runs short of memory: what is cheap to make again. The decoded pictures
/// of the image cache come back from TDLib's files, and the histories of
/// the chats that are not open load again when opened.
@MainActor
final class MemoryShedTests: XCTestCase {
    private var apps: [AppState] = []

    override func tearDown() async throws {
        for app in apps {
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        try await super.tearDown()
    }

    // MARK: - The image cache

    func testTrimLetsTheLeastRecentlyUsedPicturesGoUntilTheRestFit() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let pictures = try await fill(cache, service: service, count: 8, side: 64)
        let onePicture = cache.decodedImageBytes / 8

        cache.trim(toDecodedBytes: onePicture * 3)

        XCTAssertLessThanOrEqual(cache.decodedImageBytes, onePicture * 3)
        XCTAssertEqual(pictures.map { $0.value != nil }, [false, false, false, false, false, true, true, true],
                       "The three used last stay; the cache was the only holder of the others")
    }

    /// A load that is downloading or decoding is not the cache's to drop: it
    /// finishes, and its picture takes its place as usual.
    func testTrimLeavesALoadInProgressToFinish() async throws {
        let files = RecordingFiles()
        let cache = ImageCache(service: files)
        let load = Task { await cache.load(fileId: "7") }
        try await waitUntil { files.started == ["7"] }

        cache.trim(toDecodedBytes: 0)
        files.release()
        let image = await load.value

        XCTAssertNotNil(image)
        XCTAssertGreaterThan(cache.decodedImageBytes, 0, "The finished load is cached")
    }

    /// The loads running when the limit is lowered finish within it, and
    /// the limit is lifted on request.
    func testLoadsInProgressWhenTheLimitIsLoweredStoreWithinIt() async throws {
        let files = RecordingFiles(payload: RecordingFiles.imageData(width: 64, height: 64))
        let cache = ImageCache(service: files)
        let loads = (0..<10).map { index in
            Task { await cache.load(fileId: "inflight-\(index)", maxDimension: 64) }
        }
        try await waitUntil { files.started.count == 10 }

        cache.limitDecodedBytes(to: 64 * 64 * 4 * 3)
        files.release()
        for load in loads {
            _ = await load.value
        }

        XCTAssertLessThanOrEqual(cache.decodedImageBytes, 64 * 64 * 4 * 3, "Ten pictures finished into a limit of three")

        cache.restoreDecodedByteLimit()
        for index in 10..<20 {
            _ = await cache.load(fileId: "inflight-\(index)", maxDimension: 64)
        }
        XCTAssertGreaterThan(cache.decodedImageBytes, 64 * 64 * 4 * 3, "The full budget is back")
    }

    // MARK: - Background

    /// A suspended app with a smaller footprint is a later choice for
    /// jetsam. The latest pictures stay, for the screen the user comes back to.
    func testBackgroundKeepsOnlyTheLatestPictures() async throws {
        let (app, service) = makeApp()
        let pictures = try await fill(app.imageCache, service: service, count: 20, side: 256)
        XCTAssertGreaterThan(app.imageCache.decodedImageBytes, 4 << 20, "Twenty 256 px bitmaps are 5 MB")

        app.handleEnteredBackground()

        XCTAssertLessThanOrEqual(app.imageCache.decodedImageBytes, AppConstants.Cache.backgroundDecodedImageBytes)
        XCTAssertNil(pictures.first?.value, "The oldest picture goes")
        XCTAssertNotNil(pictures.last?.value, "The latest picture stays")
    }

    /// The app runs for a moment after it goes to the background. Loads that
    /// were in flight finish then, and their pictures must not fill the cache
    /// up to its full budget again just before the app is suspended.
    func testPicturesLoadedAfterGoingToTheBackgroundStayWithinTheBackgroundBudget() async throws {
        let (app, service) = makeApp()
        app.handleEnteredBackground()

        let pictures = try await fill(app.imageCache, service: service, count: 20, side: 256)

        XCTAssertLessThanOrEqual(app.imageCache.decodedImageBytes, AppConstants.Cache.backgroundDecodedImageBytes)
        XCTAssertNil(pictures.first?.value, "The oldest picture goes")
        XCTAssertNotNil(pictures.last?.value, "The latest picture stays")
    }

    /// The smaller budget is for the time the app is away only.
    func testBecomingActiveGivesTheCacheItsFullBudgetBack() async throws {
        let (app, service) = makeApp()
        app.isInitialized = true
        app.handleEnteredBackground()
        app.handleBecameActive()

        _ = try await fill(app.imageCache, service: service, count: 20, side: 256)

        XCTAssertGreaterThan(app.imageCache.decodedImageBytes, 4 << 20, "Twenty 256 px bitmaps are 5 MB")
    }

    // MARK: - Memory pressure

    func testMemoryPressureLetsEveryCachedPictureGo() async throws {
        let (app, service) = makeApp()
        let pictures = try await fill(app.imageCache, service: service, count: 5, side: 64)

        app.handleMemoryPressure()

        XCTAssertEqual(app.imageCache.decodedImageBytes, 0)
        XCTAssertTrue(pictures.allSatisfy { $0.value == nil }, "Nothing else held them")
    }

    /// The chat on screen keeps its history.
    func testMemoryPressureFreesTheHistoriesOfTheChatsNotOpen() {
        let (app, _) = makeApp()
        let store = app.chatMessageStore
        for chatId: Int64 in [1, 2] {
            store.reset(chatId: chatId)
            store.handleIncomingMessage(MessageInfo(
                id: chatId, chatId: chatId, senderName: "Alice", senderId: 2, content: .text("Hi"),
                date: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: false, isRead: false
            ))
        }
        store.setActiveChat(2)

        app.handleMemoryPressure()

        XCTAssertTrue(store.messages(for: 1).isEmpty, "A chat that is not open loads again when opened")
        XCTAssertEqual(store.messages(for: 2).map(\.id), [2], "The open chat keeps its history")
    }

    // MARK: - The pressure monitor

    func testMonitorActivatesItsSourceOnceAndReportsEveryEvent() {
        let source = ManualPressureSource()
        let reports = OSAllocatedUnfairLock(initialState: 0)

        let monitor = MemoryPressureMonitor(source: source) { reports.withLock { $0 += 1 } }
        XCTAssertEqual(source.activations, 1, "A source that is not activated reports nothing")
        source.raise()
        source.raise()

        XCTAssertEqual(reports.withLock { $0 }, 2)
        withExtendedLifetime(monitor) {}
    }

    func testMonitorStopsItsSourceWhenItIsReleased() {
        let source = ManualPressureSource()
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor(source: source) {}
        XCTAssertFalse(source.isCancelled)

        monitor = nil

        XCTAssertTrue(source.isCancelled, "The source outlives its owner otherwise")
        XCTAssertNil(monitor)
    }

    /// libdispatch aborts the process when a source is released before it is
    /// activated; one released active and not cancelled stays registered
    /// with the system.
    func testTheSystemsSourceStartsAndStopsWithItsMonitor() {
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor(
            source: DispatchMemoryPressureSource(queue: DispatchQueue(label: "MemoryShedTests.pressure"))
        ) {}

        monitor = nil

        XCTAssertNil(monitor)
    }

    /// The app owns a monitor and answers its events by shedding.
    func testAppShedsWhenItsSourceReportsPressure() async throws {
        let source = ManualPressureSource()
        let (app, service) = makeApp(pressureSource: source)
        XCTAssertEqual(source.activations, 1)
        _ = try await fill(app.imageCache, service: service, count: 5, side: 64)
        XCTAssertGreaterThan(app.imageCache.decodedImageBytes, 0)

        source.raise()

        try await waitUntil { app.imageCache.decodedImageBytes == 0 }
    }

    // MARK: - Helpers

    private func makeApp(pressureSource: (any MemoryPressureSource)? = nil) -> (AppState, MockTelegramService) {
        let service = MockTelegramService()
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults()),
            memoryPressureSource: pressureSource
        )
        app.networkMonitor.pause()
        apps.append(app)
        return (app, service)
    }

    /// Loads `count` pictures into the cache, oldest first, and returns weak
    /// references to them: a picture stays alive only while the cache holds it.
    private func fill(_ cache: ImageCache, service: MockTelegramService, count: Int, side: Int) async throws -> [WeakPicture] {
        let data = try Self.pngData(side: side)
        var pictures: [WeakPicture] = []
        for index in 0..<count {
            let fileId = "shed-\(index)"
            service.downloadedFiles[fileId] = data
            let picture = WeakPicture()
            picture.value = await cache.load(fileId: fileId, maxDimension: CGFloat(side))
            XCTAssertNotNil(picture.value)
            pictures.append(picture)
        }
        return pictures
    }

    private static func pngData(side: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let bitmap = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A pressure source the test raises by hand.
private final class ManualPressureSource: MemoryPressureSource {
    private var handler: (@Sendable () -> Void)?
    private(set) var activations = 0
    private(set) var isCancelled = false

    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func activate() {
        activations += 1
    }

    func cancel() {
        isCancelled = true
    }

    /// A pressure event, as the system source delivers it once activated.
    func raise() {
        guard activations > 0, !isCancelled else { return }
        handler?()
    }
}

private final class WeakPicture {
    weak var value: UIImage?
}
