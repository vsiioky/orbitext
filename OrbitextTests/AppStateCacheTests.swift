import Synchronization
import XCTest
@testable import OrbitextWatch

@MainActor
final class AppStateCacheTests: XCTestCase {
    // MARK: - Clear cache

    func testClearCacheEmptiesAppCachesButLeavesTDLibsLiveFilesAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clear-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = TDLibService(databaseDirectory: directory)
        // While TDLib runs it keeps its database and downloaded media in these
        // directories; deleting them under it corrupts the session.
        let liveMedia = native.filesPath.appendingPathComponent("photos/live.jpg")
        try FileManager.default.createDirectory(at: liveMedia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: liveMedia)
        let liveDatabase = native.dbPath.appendingPathComponent("db.sqlite")
        try Data("database".utf8).write(to: liveDatabase)

        let app = makeApp(service: native)
        let recording = VoiceManager.recordingsDir.appendingPathComponent("clear-cache-\(UUID().uuidString).m4a")
        try Data("recording".utf8).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }

        await app.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path), "Voice recordings survived Clear cache")
        XCTAssertEqual(try? Data(contentsOf: liveMedia), Data("media".utf8), "Clear cache deleted TDLib's media files")
        XCTAssertEqual(try? Data(contentsOf: liveDatabase), Data("database".utf8), "Clear cache deleted TDLib's database")
    }

    func testClearCacheAsksTheTransportToDeleteItsDownloadedFiles() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        await app.clearCache()

        XCTAssertEqual(service.clearFileCacheCallCount, 1,
                       "TDLib keeps the media it downloaded until it is asked to delete them")
    }

    /// A second optimizeStorage makes TDLib abort the run in progress and scan
    /// again, and the first call then fails with "aborted".
    func testClearCacheIgnoresATapWhileOneIsRunning() async throws {
        let service = MockTelegramService()
        service.clearFileCacheDelay = .milliseconds(300)
        let app = makeApp(service: service)
        XCTAssertFalse(app.isClearingCache)

        let first = Task { await app.clearCache() }
        try await waitUntil { app.isClearingCache }
        await app.clearCache()

        XCTAssertEqual(service.clearFileCacheCallCount, 1, "The second tap started another optimizeStorage")
        XCTAssertTrue(app.isClearingCache, "The ignored tap ended the run in progress")
        await first.value
        XCTAssertFalse(app.isClearingCache)
    }

    /// Settings starts a scan when it appears and Clear cache starts another
    /// when it is done. The first one reads the directories before the
    /// clear, so it can finish last with the size from before it.
    func testAnOlderCacheScanFinishingLateDoesNotOverwriteANewerOne() async throws {
        let app = makeApp(service: MockTelegramService())
        let scans = Mutex(0)
        let releaseFirstScan = DispatchSemaphore(value: 0)
        app.scanCacheSize = { _, _ in
            let number = scans.withLock { count -> Int in
                count += 1
                return count
            }
            if number == 1 {
                _ = releaseFirstScan.wait(timeout: .now() + 5)
                return 900 * 1_048_576
            }
            return 1_048_576
        }

        app.refreshCacheSize()
        try await waitUntil { scans.withLock { $0 } == 1 }
        app.refreshCacheSize()
        try await waitUntil { app.cacheSizeMB == "1.0 MB" }
        releaseFirstScan.signal()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(app.cacheSizeMB, "1.0 MB", "The scan that started first published the size from before the clear")
    }

    func testClearCacheCanRunAgainAfterTheTransportFailed() async {
        let service = MockTelegramService()
        service.clearFileCacheError = TelegramServiceError.notStarted
        let app = makeApp(service: service)

        await app.clearCache()
        await app.clearCache()

        XCTAssertFalse(app.isClearingCache)
        XCTAssertEqual(service.clearFileCacheCallCount, 2)
    }

    func testCacheSizeShownAfterClearCacheLeavesOutWhatTheTransportDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clear-cache-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("files/videos/watched.mp4")
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: video.path, contents: nil))
        try FileHandle(forWritingTo: video).truncate(atOffset: 8 * 1_048_576)
        let service = MockTelegramService()
        service.cacheDirectories = [directory.appendingPathComponent("files")]
        service.clearsFileCache = { try? FileManager.default.removeItem(at: video) }
        let app = makeApp(service: service)

        await app.clearCache()
        try await waitUntil { app.cacheSizeMB != "…" }

        let shown = try XCTUnwrap(Double(app.cacheSizeMB.replacingOccurrences(of: " MB", with: "")))
        XCTAssertLessThan(shown, 8, "Settings still counts the video Clear cache deleted: \(app.cacheSizeMB)")
    }

    func testClearCacheStillEmptiesTheAppsCachesWhenTheTransportFails() async throws {
        let service = MockTelegramService()
        service.clearFileCacheError = TelegramServiceError.notStarted
        let app = makeApp(service: service)
        let recording = VoiceManager.recordingsDir.appendingPathComponent("clear-cache-\(UUID().uuidString).m4a")
        try Data("recording".utf8).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }

        await app.clearCache()
        try await waitUntil { app.cacheSizeMB != "…" }

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
    }

    func testCacheSizeCountsEveryDirectoryClearCacheFrees() throws {
        let playback = try XCTUnwrap(
            SharedPlaybackFiles.appGroupDirectory(), "No app-group container in this test host"
        )

        let counted = AppState.cacheDirectories(transportDirectories: [], recordingsDirectory: VoiceManager.recordingsDir)
            .map(\.standardizedFileURL)

        XCTAssertTrue(counted.contains(playback.standardizedFileURL),
                      "Clear cache frees the video copies, so Settings has to show them")
        XCTAssertTrue(counted.contains(VoiceManager.recordingsDir.standardizedFileURL))
    }

    // MARK: - Background flush

    func testBackgroundFlushWritesPendingChatListFilesOfEveryList() {
        let app = makeApp(service: MockTelegramService())
        let folderId = Int64.random(in: 400_000...499_999)
        let folderFile = app.chatRepository.cache(for: folderId)
        defer { folderFile.clear() }
        let pruned = [ChatInfo(
            id: 1, title: "Chat 1", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 5
        )]
        // A write still inside its debounce window, as pruning the file of a
        // folder that is not on screen leaves it.
        folderFile.save(pruned)

        app.flushCoalescedDiskWrites()

        let onDisk = ListCache<ChatInfo>(filename: "cached_chats_folder_\(folderId).json")
        XCTAssertEqual(onDisk.load()?.map(\.id), [1], "watchOS may suspend the app before the debounce fires")
    }

    // MARK: - FLOOD_WAIT

    func testFloodWaitRemainingReportsTheLimitTDLibReturned() async throws {
        let fixture = ScriptedServiceFixture { _ in .error(code: 420, message: "FLOOD_WAIT_30") }
        defer { fixture.finish() }
        let app = makeApp(service: fixture.service)
        XCTAssertNil(app.floodWaitRemaining, "No request has been limited yet")

        do {
            _ = try await fixture.service.throttledSend(["@type": "getChats"])
            XCTFail("The scripted client answers FLOOD_WAIT_30")
        } catch let error as TDError {
            XCTAssertEqual(error.floodWaitSeconds, 30)
        }

        let remaining = try XCTUnwrap(app.floodWaitRemaining)
        XCTAssertTrue((1...30).contains(remaining), "Expected up to 30 seconds, got \(remaining)")
    }

    func testFloodWaitRemainingIsNilOnceTheLimitHasExpired() {
        let native = TDLibService(databaseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("flood-wait-\(UUID().uuidString)"))
        let app = makeApp(service: native)

        native.requests.floodWait.withLock { $0.expiresAt = Date().addingTimeInterval(-1) }

        XCTAssertNil(app.floodWaitRemaining)
    }

    func testFloodWaitRemainingIsNilForAServiceWithoutLimits() {
        XCTAssertNil(makeApp(service: MockTelegramService()).floodWaitRemaining)
    }

    /// TDLib records a limit from its own queues while the UI polls it, so the
    /// read has to take the service's lock instead of touching the fields.
    func testFloodWaitRemainingWaitsForARecordInProgress() {
        let native = TDLibService(databaseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("flood-wait-\(UUID().uuidString)"))
        let app = makeApp(service: native)
        let recordingHasStarted = DispatchSemaphore(value: 0)
        let recordingFinished = DispatchSemaphore(value: 0)
        let hold: TimeInterval = 0.15
        DispatchQueue.global().async {
            native.requests.floodWait.withLock { floodWait in
                recordingHasStarted.signal()
                Thread.sleep(forTimeInterval: hold)
                floodWait.expiresAt = Date().addingTimeInterval(30)
            }
            recordingFinished.signal()
        }
        recordingHasStarted.wait()

        let start = ContinuousClock.now
        let remaining = app.floodWaitRemaining
        let waited = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(waited, .milliseconds(100), "The read did not wait for the limit being recorded")
        XCTAssertNotNil(remaining, "The read returned a state from before the record finished")
        recordingFinished.wait()
    }

    // MARK: - Helpers

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeApp(service: any TelegramServiceProtocol) -> AppState {
        let app = AppState(service: service, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
        app.networkMonitor.pause()
        return app
    }
}
