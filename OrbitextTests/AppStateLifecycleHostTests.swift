import XCTest
@testable import OrbitextWatch

/// What `AppState` gives the lifecycle coordinator: voice playback as a pin
/// on the transport, and its own network monitor. The coordinator tests use a
/// fake host, so these hold the real adapter.
@MainActor
final class AppStateLifecycleHostTests: XCTestCase {
    private var apps: [AppState] = []

    override func setUp() async throws {
        // AppState restores the chat list a previous run of the host app left.
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
    }

    override func tearDown() async throws {
        for app in apps {
            app.voiceManager.cleanup()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        try await super.tearDown()
    }

    func testVoicePlaybackKeepsTheTransportAwakeInTheBackground() {
        let (app, service) = makeStartedApp()
        XCTAssertTrue(app.voiceManager.play(data: VoiceManagerTests.silentWAV(), fileId: "voice"))
        XCTAssertTrue(app.voiceManager.isPlaying)

        app.handleEnteredBackground()

        XCTAssertEqual(service.suspendCallCount, 0, "The wrist went down mid-message and playback lost the connection")
    }

    func testTransportSleepsInTheBackgroundWhenNothingPlays() {
        let (app, service) = makeStartedApp()

        app.handleEnteredBackground()

        XCTAssertEqual(service.suspendCallCount, 1)
    }

    func testNetworkMonitorFollowsTheSceneAndThePlayback() {
        let (app, _) = makeStartedApp()
        XCTAssertTrue(app.networkMonitor.isMonitoring, "Activation starts the path monitor")

        app.handleEnteredBackground()
        XCTAssertFalse(app.networkMonitor.isMonitoring, "An idle background stops it")

        app.handleBecameActive()
        XCTAssertTrue(app.voiceManager.play(data: VoiceManagerTests.silentWAV(), fileId: "voice"))
        app.handleEnteredBackground()
        XCTAssertTrue(app.networkMonitor.isMonitoring, "Playback keeps it, as it keeps the transport")
    }

    // MARK: - Helpers

    /// An app whose scene is active, with the path monitor stopped first so
    /// that the activation is what starts it.
    private func makeStartedApp() -> (AppState, MockTelegramService) {
        let service = MockTelegramService()
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        apps.append(app)
        app.isInitialized = true
        app.handleBecameActive()
        return (app, service)
    }
}
