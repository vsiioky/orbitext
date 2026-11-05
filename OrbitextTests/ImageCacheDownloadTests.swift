import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OrbitextWatch

/// How ImageCache drives the transport's downloads: at the priority of the
/// readers still waiting, and stopped once none is.
@MainActor
final class ImageCacheDownloadTests: XCTestCase {
    func testLastReaderLeavingStopsTheDownload() async throws {
        let files = ControlledFiles()
        let cache = ImageCache(service: files)
        let reader = Task { await cache.loadData(fileId: "7") }
        try await waitUntil { files.started == ["7"] }

        reader.cancel()

        let data = await reader.value
        XCTAssertNil(data, "A cancelled reader must not wait for the download to finish")
        try await waitUntil { files.cancelled == ["7"] }
    }

    func testReaderLeavingKeepsTheDownloadForTheOthers() async throws {
        let files = ControlledFiles()
        let cache = ImageCache(service: files)
        let leaving = Task { await cache.loadData(fileId: "7") }
        try await waitUntil { files.started == ["7"] }
        let staying = Task { await cache.loadData(fileId: "7") }
        try await waitUntil { cache.readerCount(fileId: "7") == 2 }

        leaving.cancel()
        let left = await leaving.value
        files.release()
        let stayed = await staying.value

        XCTAssertNil(left)
        XCTAssertEqual(stayed, files.data, "The download went on for the reader that stayed")
        XCTAssertTrue(files.cancelled.isEmpty, "Another reader still waited for the file")
        XCTAssertEqual(files.started, ["7"])
    }

    func testDownloadRunsAtTheHighestPriorityOfItsReaders() async throws {
        let files = ControlledFiles()
        let cache = ImageCache(service: files)
        let offscreen = UUID(), onScreen = UUID()
        let first = Task { await cache.loadData(fileId: "7", priority: .offscreen, requester: offscreen) }
        try await waitUntil { files.started == ["7"] }
        let priority = try XCTUnwrap(files.priority(of: "7"))
        XCTAssertEqual(priority.value, .offscreen)

        let second = Task { await cache.loadData(fileId: "7", priority: .onScreen, requester: onScreen) }
        try await waitUntil { priority.value == .onScreen }
        second.cancel()
        _ = await second.value
        XCTAssertEqual(priority.value, .offscreen, "The on-screen reader is gone")

        cache.setPriority(.requested, fileId: "7", requester: offscreen)
        XCTAssertEqual(priority.value, .requested, "The user opened what the row shows")
        cache.setPriority(.onScreen, fileId: "7", requester: UUID())
        XCTAssertEqual(priority.value, .requested, "A requester that is not reading changes nothing")

        files.release()
        _ = await first.value
    }

    func testRowScrolledAwayMovesItsDownloadBack() async throws {
        let files = ControlledFiles()
        let cache = ImageCache(service: files)
        let row = UUID()
        let reader = Task { await cache.load(fileId: "7", maxDimension: 68, priority: .onScreen, requester: row) }
        try await waitUntil { files.started == ["7"] }
        let priority = try XCTUnwrap(files.priority(of: "7"))

        cache.setPriority(.offscreen, fileId: "7", requester: row)

        XCTAssertEqual(priority.value, .offscreen)
        reader.cancel()
        _ = await reader.value
    }

    func testViewerAndPlayerAskForTheRequestedPriority() async {
        let service = MockTelegramService()
        let cache = ImageCache(
            service: service,
            playbackFiles: SharedPlaybackFiles(directory: { [directory = makeDirectory()] in directory })
        )
        service.downloadedFiles["photo"] = Data([1])
        service.downloadedFiles["video"] = Data([2])

        _ = await cache.loadFullSize(fileId: "photo")
        _ = await cache.loadSharedPlaybackFile(fileId: "video")

        XCTAssertEqual(service.downloadPriorities["photo"]?.value, .requested)
        XCTAssertEqual(service.downloadPriorities["video"]?.value, .requested)
    }

    func testThumbnailsAskForTheOnScreenPriorityByDefault() async {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        service.downloadedFiles["7"] = Data([1])

        _ = await cache.loadData(fileId: "7")

        XCTAssertEqual(service.downloadPriorities["7"]?.value, .onScreen)
    }

    func testClearStopsTheRunningDownloads() async throws {
        let files = ControlledFiles()
        let cache = ImageCache(service: files)
        let reader = Task { await cache.loadData(fileId: "7") }
        try await waitUntil { files.started == ["7"] }

        cache.clear()

        try await waitUntil { files.cancelled == ["7"] }
        let data = await reader.value
        XCTAssertNil(data)
    }

    // MARK: - The photo the viewer shows

    /// An HD photo is 2560 px wide, 20 MB of bitmap at 4 bytes a pixel, on a
    /// screen 422 px wide. The viewer decodes what a watch can use.
    func testViewerPhotoLargerThanTheBoundIsDecodedWithinIt() async throws {
        let service = MockTelegramService()
        service.downloadedFiles["landscape"] = try Self.jpegData(width: 2560, height: 1920)
        service.downloadedFiles["portrait"] = try Self.jpegData(width: 1920, height: 2560)
        let cache = ImageCache(service: service)

        let landscapeImage = await cache.loadFullSize(fileId: "landscape")
        let portraitImage = await cache.loadFullSize(fileId: "portrait")
        let landscape = try XCTUnwrap(landscapeImage?.cgImage)
        let portrait = try XCTUnwrap(portraitImage?.cgImage)
        let bound = AppConstants.UI.Viewer.maxPixelSize
        XCTAssertEqual([landscape.width, landscape.height], [bound, bound * 3 / 4], "The long side is the bound and the aspect ratio stays")
        XCTAssertEqual([portrait.width, portrait.height], [bound * 3 / 4, bound])
    }

    /// A standard photo is 1280 px at most, so it keeps the pixels it has.
    func testViewerPhotoWithinTheBoundKeepsItsPixels() async throws {
        let service = MockTelegramService()
        service.downloadedFiles["standard"] = try Self.jpegData(width: 1280, height: 960)
        service.downloadedFiles["small"] = try Self.jpegData(width: 800, height: 600)
        let cache = ImageCache(service: service)

        let standardImage = await cache.loadFullSize(fileId: "standard")
        let smallImage = await cache.loadFullSize(fileId: "small")

        let standard = try XCTUnwrap(standardImage?.cgImage)
        let small = try XCTUnwrap(smallImage?.cgImage)

        XCTAssertEqual([standard.width, standard.height], [1280, 960])
        XCTAssertEqual([small.width, small.height], [800, 600], "A small photo is not stretched to the bound")
    }

    /// UIImage(data:) drew a sideways photo upright by its orientation; the
    /// decode into pixels has to apply it itself.
    func testViewerPhotoStoredSidewaysIsDecodedUpright() async throws {
        let service = MockTelegramService()
        service.downloadedFiles["sideways"] = try Self.jpegData(width: 2560, height: 1920, orientation: 6)
        let cache = ImageCache(service: service)

        let image = await cache.loadFullSize(fileId: "sideways")

        let bitmap = try XCTUnwrap(image?.cgImage)
        let bound = AppConstants.UI.Viewer.maxPixelSize
        XCTAssertEqual([bitmap.width, bitmap.height], [bound * 3 / 4, bound], "Turned a quarter, 2560x1920 is a portrait")
    }

    /// A photo decoded on first draw is decoded on the main thread, in the
    /// middle of the frame the viewer opens with.
    func testViewerPhotoIsDecodedOffTheMainThread() async throws {
        let service = MockTelegramService()
        service.downloadedFiles["photo"] = Data([1])
        let probe = ViewerDecodeProbe()
        let image = try XCTUnwrap(UIImage(data: RecordingFiles.imageData()))
        let cache = ImageCache(service: service) { _, maxPixels in
            await probe.record(ViewerDecodeProbe.Call(isMainThread: pthread_main_np() != 0, maxPixels: maxPixels))
            return image
        }

        let loaded = await cache.loadFullSize(fileId: "photo")

        XCTAssertTrue(loaded === image)
        let calls = await probe.calls
        XCTAssertEqual(calls, [ViewerDecodeProbe.Call(isMainThread: false, maxPixels: AppConstants.UI.Viewer.maxPixelSize)])
    }

    /// The memory budget of the cache is for the tiles of the chat: the
    /// bitmap of the viewer is the viewer's, and goes with it.
    func testViewerPhotoIsNotKeptInTheThumbnailCache() async throws {
        let service = MockTelegramService()
        service.downloadedFiles["photo"] = try Self.jpegData(width: 1280, height: 960)
        let cache = ImageCache(service: service)

        let loaded = await cache.loadFullSize(fileId: "photo")

        XCTAssertNotNil(loaded)
        let kept = await cache.cachedData(fileId: "photo")
        XCTAssertNil(kept, "Nothing of the viewer's photo may take a place in the cache")
    }

    // MARK: - File ids live as long as one TDLib instance

    /// TDLib numbers files as they register in one instance
    /// (FileManager::next_file_id), so after a relaunch the same id can name
    /// another file. Bytes kept under an id from the earlier run are another
    /// file's bytes.
    func testFileIdOfAnEarlierRunIsAnsweredWithThisRunsFile() async {
        let earlierRun = MockTelegramService()
        earlierRun.downloadedFiles["200"] = Data("photo of the earlier run".utf8)
        _ = await ImageCache(service: earlierRun).loadData(fileId: "200")

        let thisRun = MockTelegramService()
        thisRun.downloadedFiles["200"] = Data("sticker of this run".utf8)
        let data = await ImageCache(service: thisRun).loadData(fileId: "200")

        XCTAssertEqual(data, Data("sticker of this run".utf8))
    }

    func testCopiesOfTheOldMediaCacheAreDeleted() async throws {
        let caches = makeDirectory()
        let old = caches.appendingPathComponent("media_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("copy of a TDLib file".utf8).write(to: old.appendingPathComponent("0f1e2d"))
        let other = caches.appendingPathComponent("cached_chats.json")
        try Data("[]".utf8).write(to: other)

        await ImageCache.removeLegacyDiskCache(in: caches)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "Up to 25 MB of copies stay on the watch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    /// File ids are numbered per TDLib instance, so a copy left by an earlier
    /// run is named after a file that is another one now.
    func testPlaybackCopiesOfEarlierRunsAreDeletedAtLaunch() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = directory.appendingPathComponent("200.mp4")
        try Data("video of an earlier run".utf8).write(to: leftover)
        let queue = DispatchQueue(label: "ImageCacheDownloadTests.playback")
        let cache = ImageCache(service: MockTelegramService(), playbackFiles: SharedPlaybackFiles(directory: { directory }, queue: queue))

        cache.removePlaybackCopiesOfEarlierRuns()
        queue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "Up to a video's size stays on the watch")
    }

    // MARK: - Helpers

    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        try await super.tearDown()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-cache-\(UUID().uuidString)")
        directories.append(directory)
        return directory
    }

    /// `orientation` is the EXIF value of a photo the camera held sideways.
    private static func jpegData(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bitmap = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, bitmap, properties)
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

/// Downloads that wait until released, and record their start, their
/// priority and whether their caller cancelled them.
private final class ControlledFiles: TelegramFileAccess, @unchecked Sendable {
    let data = Data("downloaded".utf8)
    private let lock = NSLock()
    private var startedIds: [String] = []
    private var cancelledIds: [String] = []
    private var priorities: [String: DownloadPriorityHandle] = [:]
    private var isReleased = false

    var started: [String] { lock.withLock { startedIds } }
    var cancelled: [String] { lock.withLock { cancelledIds } }

    func priority(of fileId: String) -> DownloadPriorityHandle? {
        lock.withLock { priorities[fileId] }
    }

    func release() {
        lock.withLock { isReleased = true }
    }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        lock.withLock {
            startedIds.append(fileId)
            priorities[fileId] = priority
        }
        do {
            while !lock.withLock({ isReleased }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            lock.withLock { cancelledIds.append(fileId) }
            throw error
        }
        return data
    }
}

/// What the decoder of the cache was asked for, and on which thread.
private actor ViewerDecodeProbe {
    struct Call: Equatable, Sendable {
        let isMainThread: Bool
        let maxPixels: Int
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }
}
