import WatchKit
import XCTest
@testable import OrbitextWatch

/// The video viewer's inline movie player: when it gives WatchKit's movie a
/// file, and what it leaves on the watch when it closes.
@MainActor
final class VideoPlayerViewTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
        try await super.tearDown()
    }

    // MARK: - The movie

    /// SwiftUI updates the representable whenever its environment changes,
    /// as when the wrist goes down. A movie given its URL again started over
    /// at 0:00 with a new player item.
    func testAnUpdateWithTheSameMovieDoesNotLoadItAgain() {
        let movie = SpyMovie()
        let loader = InlineMovieLoader()
        let url = URL(fileURLWithPath: "/tmp/video-7.mp4")

        loader.show(url, in: movie)
        loader.show(url, in: movie)

        XCTAssertEqual(movie.loadedURLs, [url])
        XCTAssertEqual(movie.plays, 1)
    }

    func testAnotherMovieIsLoaded() {
        let movie = SpyMovie()
        let loader = InlineMovieLoader()
        let first = URL(fileURLWithPath: "/tmp/video-7.mp4")
        let second = URL(fileURLWithPath: "/tmp/video-8.mp4")

        loader.show(first, in: movie)
        loader.show(second, in: movie)

        XCTAssertEqual(movie.loadedURLs, [first, second])
    }

    func testClosingThePlayerPausesTheMovie() {
        let movie = SpyMovie()
        let loader = InlineMovieLoader()
        let url = URL(fileURLWithPath: "/tmp/video-7.mp4")
        loader.show(url, in: movie)

        loader.close(movie)

        XCTAssertEqual(movie.pauses, 1, "The sound stops with the player")
        loader.show(url, in: movie)
        XCTAssertEqual(movie.loadedURLs, [url, url], "A player shown again starts the movie")
    }

    // MARK: - The playback copy

    /// The player reads a copy of the video in the app group. Closing it left
    /// the copy there until the next video or Clear cache; the player asks
    /// the cache to remove it when it closes.
    func testRemovingThePlaybackCopyLeavesTheTransportsFileAlone() async throws {
        let (cache, directory, source) = try makeCacheWithVideo(fileId: "7")
        let copy = await cache.loadSharedPlaybackFile(fileId: "7")
        XCTAssertNotNil(copy)
        XCTAssertEqual(Self.copies(in: directory), 1)

        cache.removeSharedPlaybackFile(fileId: "7")

        try await waitUntil("The copy stayed after the player closed") { Self.copies(in: directory) == 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "TDLib's own file is not the player's to delete")
    }

    /// The user closes the video and opens it again at once: the removal of
    /// the first copy cannot take the second one.
    func testVideoOpenedAgainRightAfterClosingKeepsItsNewCopy() async throws {
        let (cache, directory, _) = try makeCacheWithVideo(fileId: "7")
        _ = await cache.loadSharedPlaybackFile(fileId: "7")

        cache.removeSharedPlaybackFile(fileId: "7")
        let reopened = await cache.loadSharedPlaybackFile(fileId: "7")

        let copy = try XCTUnwrap(reopened)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(Self.copies(in: directory), 1)
    }

    // MARK: - Helpers

    /// A cache whose playback copies go to a directory of their own, over a
    /// transport that holds the video `fileId` as a file.
    private func makeCacheWithVideo(fileId: String) throws -> (ImageCache, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString)")
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).mp4")
        try Data("transport video".utf8).write(to: source)
        cleanups.append { try? FileManager.default.removeItem(at: source) }
        let service = MockTelegramService()
        service.localFileURLs[fileId] = source
        let cache = ImageCache(service: service, playbackFiles: SharedPlaybackFiles(directory: { directory }))
        return (cache, directory, source)
    }

    private static func copies(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    private func waitUntil(_ message: String, timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Records what the player asks of the movie.
@MainActor
private final class SpyMovie: InlineMovie {
    var loadedURLs: [URL] = []
    var plays = 0
    var pauses = 0

    func setMovieURL(_ url: URL) {
        loadedURLs.append(url)
    }

    func setVideoGravity(_ videoGravity: WKVideoGravity) {}
    func setLoops(_ loops: Bool) {}
    func setAutoplays(_ autoplays: Bool) {}

    func play() {
        plays += 1
    }

    func pause() {
        pauses += 1
    }
}
