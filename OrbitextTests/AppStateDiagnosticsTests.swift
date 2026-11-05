import XCTest
@testable import OrbitextWatch

/// AppState and Settings read the transport's diagnostics through the
/// diagnostics protocol, so the mock answers them like TDLibService does.
/// The native FLOOD_WAIT twin is AppStateCacheTests.
@MainActor
final class AppStateDiagnosticsTests: XCTestCase {
    func testFloodWaitRemainingComesFromTheTransport() {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        XCTAssertNil(app.floodWaitRemaining)

        service.floodWaitRemainingSeconds = 42

        XCTAssertEqual(app.floodWaitRemaining, 42)

        service.floodWaitRemainingSeconds = nil

        XCTAssertNil(app.floodWaitRemaining)
    }

    func testCacheSizeCountsTheTransportsCacheDirectories() async throws {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        // Recordings and media left by other tests count too, so compare.
        let baseline = try await measureCacheSizeMB(of: app)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 2 * 1_048_576).write(to: directory.appendingPathComponent("photo.jpg"))
        service.cacheDirectories = [directory]

        let withFiles = try await measureCacheSizeMB(of: app)

        XCTAssertGreaterThanOrEqual(withFiles - baseline, 1.9, "The files Clear cache deletes are the cache Settings shows")
    }

    /// After Clear cache the number has to go near zero, or it reads as a
    /// clear that failed: the database and the binlog are not the cache.
    func testCacheSizeLeavesOutTheDatabaseOfTheNativeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = TDLibService(databaseDirectory: directory)
        let app = makeApp(service: native)
        try FileManager.default.createDirectory(at: native.filesPath.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native.voiceUploadDirectory, withIntermediateDirectories: true)
        let baseline = try await measureCacheSizeMB(of: app)
        try Data(count: 5 * 1_048_576).write(to: directory.appendingPathComponent("db.sqlite"))
        try Data(count: 5 * 1_048_576).write(to: directory.appendingPathComponent("td.binlog"))
        try Data(count: 2 * 1_048_576).write(to: native.filesPath.appendingPathComponent("photos/seen.jpg"))
        try Data(count: 1 * 1_048_576).write(to: native.voiceUploadDirectory.appendingPathComponent("sent.m4a"))

        let measured = try await measureCacheSizeMB(of: app)

        XCTAssertGreaterThanOrEqual(measured - baseline, 2.9, "Media and the copies of sent voice notes are the cache")
        XCTAssertLessThan(measured - baseline, 3.5, "The database is not something Clear cache can free")
    }

    func testNativeDiagnosticsReachTheProtocol() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        let native = TDLibService(databaseDirectory: directory)
        let diagnostics: any TelegramDiagnostics = native

        XCTAssertEqual(Set(diagnostics.cacheDirectories.map(\.lastPathComponent)), ["files", "voice-uploads"])
        if AppLogSettings.tdTelemetryEnabled {
            // `nil === nil` would pass when the protocol's default answered.
            let telemetry = try XCTUnwrap(native.telemetry, "Telemetry is enabled for this run")
            XCTAssertIdentical(diagnostics.telemetry, telemetry)
        } else {
            // Release builds, --no-td-telemetry and TD_TELEMETRY other than 1.
            XCTAssertNil(native.telemetry)
            XCTAssertNil(diagnostics.telemetry)
        }
        XCTAssertNil(diagnostics.currentFloodWaitRemaining())
        native.requests.floodWait.withLock { $0.expiresAt = Date().addingTimeInterval(30) }
        let remaining = try XCTUnwrap(diagnostics.currentFloodWaitRemaining())
        XCTAssertTrue((1...30).contains(remaining), "Expected up to 30 seconds, got \(remaining)")
    }

    // MARK: - Helpers

    /// refreshCacheSize measures on a detached task and publishes the text.
    private func measureCacheSizeMB(of app: AppState) async throws -> Double {
        app.cacheSizeMB = "…"
        app.refreshCacheSize()
        let deadline = ContinuousClock.now + .seconds(5)
        while app.cacheSizeMB == "…", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = app.cacheSizeMB.replacingOccurrences(of: " MB", with: "")
        return try XCTUnwrap(Double(text), "refreshCacheSize published \(app.cacheSizeMB)")
    }

    private func makeApp(service: any TelegramServiceProtocol) -> AppState {
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        return app
    }
}
