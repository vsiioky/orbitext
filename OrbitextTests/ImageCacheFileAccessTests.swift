import XCTest
@testable import OrbitextWatch

/// ImageCache reaches the transport's own files through the file-access
/// protocol, not by asking whether the service is a TDLibService, so every
/// transport takes the same playback path.
@MainActor
final class ImageCacheFileAccessTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() async throws {
        cleanups.forEach { $0() }
        cleanups = []
        try await super.tearDown()
    }

    func testSharedPlaybackCopiesTheTransportsFileInsteadOfDownloadingIt() async throws {
        let service = MockTelegramService()
        let cache = try makeCache(service: service)
        let (id, source) = try makeTransportFile(bytes: "transport video")
        service.localFileURLs[id] = source

        let loaded = await cache.loadSharedPlaybackFile(fileId: id)
        let playback = try XCTUnwrap(loaded)

        XCTAssertEqual(try Data(contentsOf: playback), Data("transport video".utf8))
        XCTAssertNotEqual(playback.standardizedFileURL, source.standardizedFileURL, "Playback needs its own copy")
        XCTAssertEqual(service.requestedLocalFileURLs, [id])
        XCTAssertTrue(service.requestedDownloads.isEmpty, "The file was on disk; reading it into memory is wasted work")
    }

    func testSharedPlaybackFallsBackToDownloadedDataWhenTheTransportKeepsNoFiles() async throws {
        let service = MockTelegramService()
        let cache = try makeCache(service: service)
        let id = "playback-fallback-\(UUID().uuidString)"
        service.localFileURLError = TelegramServiceError.unsupported
        service.downloadedFiles[id] = Data("downloaded video".utf8)

        let loaded = await cache.loadSharedPlaybackFile(fileId: id)
        let playback = try XCTUnwrap(loaded)

        XCTAssertEqual(try Data(contentsOf: playback), Data("downloaded video".utf8))
        XCTAssertEqual(service.requestedLocalFileURLs, [id])
        XCTAssertEqual(service.requestedDownloads, [id])
    }

    /// The fallback is for a transport that has no files of its own. A request
    /// that failed (no network, a stalled download) would only fail again as a
    /// download, after another full wait.
    func testSharedPlaybackDoesNotDownloadAgainAfterTheTransportRequestFailed() async {
        let service = MockTelegramService()
        let cache = makeIsolatedCache(service: service)
        let id = "playback-failed-\(UUID().uuidString)"
        service.localFileURLError = TDError.timeout
        service.downloadedFiles[id] = Data("downloaded video".utf8)

        let loaded = await cache.loadSharedPlaybackFile(fileId: id)

        XCTAssertNil(loaded)
        XCTAssertEqual(service.requestedLocalFileURLs, [id])
        XCTAssertTrue(service.requestedDownloads.isEmpty, "A second download means a second wait for the same file")
    }

    func testStalledVideoIsDownloadedOnceBeforeItFails() async {
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(200), downloadProgressInterval: .milliseconds(40)
        ) { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            return .result([
                "@type": "file", "id": 314, "size": 1000, "expected_size": 1000,
                "local": ["@type": "localFile", "path": "/tmp/partial", "is_downloading_active": true,
                          "is_downloading_completed": false, "downloaded_size": 4]
            ])
        }
        defer { fixture.finish() }
        let cache = makeIsolatedCache(service: fixture.service)

        let loaded = await cache.loadSharedPlaybackFile(fileId: "314")

        XCTAssertNil(loaded, "Nothing arrived: the video cannot be opened")
        XCTAssertEqual(fixture.transport.requests(ofType: "downloadFile").count, 1,
                       "The fallback must not start the stalled download over")
    }

    func testTransportFileSurvivesInvalidateAndClear() async throws {
        let service = MockTelegramService()
        let cache = try makeCache(service: service)
        let (id, source) = try makeTransportFile(bytes: "transport video")
        service.localFileURLs[id] = source
        let loaded = await cache.loadSharedPlaybackFile(fileId: id)
        _ = try XCTUnwrap(loaded)

        cache.invalidate(fileId: id)
        cache.clear()

        XCTAssertEqual(try Data(contentsOf: source), Data("transport video".utf8),
                       "The transport owns the file: the cache may copy it, never delete it")
    }

    /// The mock is a hand-written answer; this runs the real transport through
    /// `any TelegramFileAccess`: the playback copy comes from the file TDLib
    /// already holds, without a download request.
    func testNativeTransportFileIsCopiedForPlaybackNotBufferedInTheMediaCache() async throws {
        let (_, source) = try makeTransportFile(bytes: "native video")
        let fixture = ScriptedServiceFixture { _ in
            .result([
                "@type": "file", "id": 314, "size": 12, "expected_size": 12,
                "local": ["@type": "localFile", "path": source.path,
                          "is_downloading_completed": true, "downloaded_size": 12]
            ])
        }
        defer { fixture.finish() }
        let cache = try makeCache(service: fixture.service)
        let id = String(Int.random(in: 900_000...999_999))

        let loaded = await cache.loadSharedPlaybackFile(fileId: id)
        let playback = try XCTUnwrap(loaded)

        XCTAssertEqual(try Data(contentsOf: playback), Data("native video".utf8))
        XCTAssertEqual(fixture.transport.methods, ["getFile"], "TDLib holds the whole file: no download request")
    }

    /// The skip-able test above needs the app-group container, so a host
    /// without it would report signature drift as "skipped". This one needs no
    /// container: the real transport answers `localFileURL` through the
    /// protocol, not through the default that throws unsupported.
    func testNativeTransportAnswersLocalFileURLThroughTheProtocol() async throws {
        let (_, source) = try makeTransportFile(bytes: "native video")
        let fixture = ScriptedServiceFixture { _ in
            .result([
                "@type": "file", "id": 314, "size": 12, "expected_size": 12,
                "local": ["@type": "localFile", "path": source.path,
                          "is_downloading_completed": true, "downloaded_size": 12]
            ])
        }
        defer { fixture.finish() }
        let files: any TelegramFileAccess = fixture.service

        let url = try await files.localFileURL(fileId: "314")

        XCTAssertEqual(url.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(fixture.transport.methods, ["getFile"])
    }

    /// A transport with no file store of its own keeps the protocol's default.
    func testTransportWithoutALocalPathFallsBackToItsDownloadedData() async throws {
        let files = DownloadOnlyFiles(data: Data("downloaded video".utf8))
        let cache = try makeCache(service: files)
        let id = "playback-download-only-\(UUID().uuidString)"

        let loaded = await cache.loadSharedPlaybackFile(fileId: id)
        let playback = try XCTUnwrap(loaded)

        XCTAssertEqual(try Data(contentsOf: playback), Data("downloaded video".utf8))
        XCTAssertEqual(files.requestedIds, [id])
        do {
            _ = try await files.localFileURL(fileId: id)
            XCTFail("The default answer must be unsupported")
        } catch TelegramServiceError.unsupported {
            // Expected.
        }
    }

    // MARK: - Helpers

    private func makeCache(service: any TelegramFileAccess) throws -> ImageCache {
        // The playback copies live in the shared app-group container.
        try XCTSkipIf(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.App.widgetSuite) == nil,
            "No app-group container in this test host"
        )
        let cache = ImageCache(service: service)
        cleanups.append { cache.clear() }
        return cache
    }

    /// A cache whose playback copies go to a directory of its own, so the test
    /// needs no app-group container.
    private func makeIsolatedCache(service: any TelegramFileAccess) -> ImageCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID().uuidString)")
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        return ImageCache(service: service, playbackFiles: SharedPlaybackFiles(directory: { directory }))
    }

    private func makeTransportFile(bytes: String) throws -> (id: String, url: URL) {
        let id = "playback-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).mp4")
        try Data(bytes.utf8).write(to: url)
        cleanups.append { try? FileManager.default.removeItem(at: url) }
        return (id, url)
    }
}

/// Implements only what the protocol requires.
private final class DownloadOnlyFiles: TelegramFileAccess, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var ids: [String] = []

    init(data: Data) { self.data = data }

    var requestedIds: [String] { lock.withLock { ids } }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        lock.withLock { ids.append(fileId) }
        return data
    }
}
