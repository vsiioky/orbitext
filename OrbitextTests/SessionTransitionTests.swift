import XCTest
@testable import OrbitextWatch

/// Logout and the destructive auth reset are session transitions: only one
/// runs at a time, in either order. The rule lives on `AppLifecycleState`;
/// these tests hold it at the place the user reaches it, `AppState`.
@MainActor
final class SessionTransitionTests: XCTestCase {
    private var apps: [AppState] = []

    override func setUp() async throws {
        // AppState restores the chat list a previous run of the host app left.
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
    }

    override func tearDown() async throws {
        for app in apps {
            app.eventTask?.cancel()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        try await super.tearDown()
    }

    // MARK: - Logout and reset exclude each other

    func testSecondLogoutWhileOneRunsIsIgnored() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.logoutGate = gate
        let first = Task { await app.logout() }
        await waitUntil { gate.arrivals == 1 }

        var secondReturned = false
        let second = Task {
            await app.logout()
            secondReturned = true
        }
        await waitUntil { secondReturned || gate.arrivals > 1 }
        let ignored = secondReturned
        gate.open()
        await first.value
        await second.value

        XCTAssertTrue(ignored, "A second tap on Log out waited for the first one instead of being ignored")
        XCTAssertEqual(service.logoutCallCount, 1, "The session would be signed out and wiped twice")
    }

    func testLogoutDuringAResetIsIgnored() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.resetLocalSessionGate = gate
        let reset = Task { await app.resetAuthMethodSelection() }
        await waitUntil { gate.arrivals == 1 }

        var logoutReturned = false
        let logout = Task {
            await app.logout()
            logoutReturned = true
        }
        await waitUntil { logoutReturned || service.logoutCallCount > 0 }
        let ignored = logoutReturned
        gate.open()
        await reset.value
        await logout.value

        XCTAssertTrue(ignored, "A logout during a reset interleaved with it")
        XCTAssertEqual(service.logoutCallCount, 0)
        XCTAssertEqual(service.resetLocalSessionCallCount, 1)
    }

    func testResetDuringALogoutIsIgnored() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.logoutGate = gate
        let logout = Task { await app.logout() }
        await waitUntil { gate.arrivals == 1 }

        var resetReturned = false
        let reset = Task {
            await app.resetAuthMethodSelection()
            resetReturned = true
        }
        await waitUntil { resetReturned || service.retryStartupCallCount > 0 }
        let ignored = resetReturned
        gate.open()
        await logout.value
        await reset.value

        XCTAssertTrue(ignored, "A reset during a logout interleaved with it")
        XCTAssertEqual(service.resetLocalSessionCallCount, 0)
        XCTAssertEqual(service.retryStartupCallCount, 0, "An ignored reset must not touch the transport")
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
    }

    func testRetryDuringALogoutIsIgnored() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.logoutGate = gate
        let logout = Task { await app.logout() }
        await waitUntil { gate.arrivals == 1 }

        var retryReturned = false
        let retry = Task {
            await app.retry()
            retryReturned = true
        }
        await waitUntil { retryReturned || service.retryStartupCallCount > 0 }
        let ignored = retryReturned
        let showedLoading = app.authManager.isLoading
        gate.open()
        await logout.value
        await retry.value

        XCTAssertTrue(ignored, "A retry during a logout interleaved with it")
        XCTAssertFalse(showedLoading)
        XCTAssertEqual(service.resetLocalSessionCallCount, 0)
        XCTAssertEqual(service.retryStartupCallCount, 0)
    }

    func testLogoutIsAcceptedAgainAfterAFailedLogout() async {
        let (app, service) = makeApp()
        service.logoutError = TestError.failed("offline")

        await app.logout()
        XCTAssertEqual(app.authManager.authState, .error("offline"))

        service.logoutError = nil
        await app.logout()

        XCTAssertEqual(service.logoutCallCount, 2, "A failed logout left the transition open")
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
    }

    func testResetIsAcceptedAfterALogoutEnded() async {
        let (app, service) = makeApp()

        await app.logout()
        await app.resetAuthMethodSelection()

        XCTAssertEqual(service.logoutCallCount, 1)
        XCTAssertEqual(service.resetLocalSessionCallCount, 1, "A finished logout left the transition open")
    }

    // MARK: - The transport stays awake for a transition

    func testLeavingTheSceneDuringALogoutKeepsTheTransportUntilItEnds() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.logoutGate = gate
        app.isInitialized = true
        app.handleBecameActive()
        let logout = Task { await app.logout() }
        await waitUntil { gate.arrivals == 1 }

        // Tap Log out, then lower the wrist: the sign-out still needs the receive loop.
        app.handleEnteredBackground()
        let suspendsDuringLogout = service.suspendCallCount
        gate.open()
        await logout.value

        XCTAssertEqual(suspendsDuringLogout, 0, "The transport slept under a logout in flight")
        XCTAssertEqual(service.suspendCallCount, 1, "The scene is away, so the transport sleeps once the logout ends")
    }

    func testLeavingTheSceneDuringAResetKeepsTheTransportUntilItEnds() async {
        let (app, service) = makeApp()
        let gate = MockRequestGate()
        service.resetLocalSessionGate = gate
        app.isInitialized = true
        app.handleBecameActive()
        let reset = Task { await app.resetAuthMethodSelection() }
        await waitUntil { gate.arrivals == 1 }

        app.handleEnteredBackground()
        let suspendsDuringReset = service.suspendCallCount
        gate.open()
        await reset.value

        XCTAssertEqual(suspendsDuringReset, 0, "The transport slept under a reset in flight")
        XCTAssertEqual(service.suspendCallCount, 1)
    }

    // MARK: - Events of an ended client

    func testStaleAuthStatesOfALoggedOutClientNeverReachTheScreen() async {
        let (app, service) = makeApp(consumesEvents: false)
        queueEventsOfTheEndedClient(on: service)

        await app.logout()
        let screens = await replay(5, of: service, on: app)

        XCTAssertEqual(screens.states, Array(repeating: .waitPhoneNumber, count: 5),
                       "A late state of the old client flashed over the sign-in screen")
        XCTAssertEqual(screens.labels, ["auth ready", "auth closing", "chat", "generation", "auth waitPhoneNumber"])
        XCTAssertTrue(app.chatRepository.chats.isEmpty, "The old account's chat came back")
    }

    func testStaleAuthStatesOfAResetClientNeverReachTheScreen() async {
        let (app, service) = makeApp(consumesEvents: false)
        queueEventsOfTheEndedClient(on: service)

        await app.resetAuthMethodSelection()
        // The restart that follows the reset announces the fresh state once more.
        let screens = await replay(6, of: service, on: app)

        XCTAssertEqual(screens.states, Array(repeating: .waitPhoneNumber, count: 6),
                       "A late state of the old client flashed over the sign-in screen")
        XCTAssertEqual(screens.labels,
                       ["auth ready", "auth closing", "chat", "generation", "auth waitPhoneNumber", "auth waitPhoneNumber"])
        XCTAssertTrue(app.chatRepository.chats.isEmpty, "The old account's chat came back")
    }

    /// What the old client had produced and the consumer had not read when
    /// the session ended.
    private func queueEventsOfTheEndedClient(on service: MockTelegramService) {
        let chat = ChatInfo(id: 501, title: "Old account", lastMessage: nil, unreadCount: 0,
                            isGroup: false, isMuted: false, order: 9)
        service.emit(.authStateChanged(.ready))
        service.emit(.authStateChanged(.closing))
        service.emit(.chatPositionChanged(.init(
            chat: chat,
            positions: [ChatListPosition(list: .main, order: 9, isPinned: false)],
            source: .explicitPosition
        )))
    }

    /// Hands the next `count` events of the stream to the app one by one and
    /// records which auth state the screen shows after each, so a stale state
    /// is seen even when a later event puts the right one back.
    private func replay(_ count: Int, of service: MockTelegramService, on app: AppState)
        async -> (states: [AuthState], labels: [String]) {
        var iterator = service.events.makeAsyncIterator()
        var states: [AuthState] = []
        var labels: [String] = []
        for _ in 0..<count {
            guard let event = await iterator.next() else { break }
            app.handleEvent(event)
            states.append(app.authManager.authState)
            labels.append(Self.label(event))
        }
        return (states, labels)
    }

    private static func label(_ event: TDLibEvent) -> String {
        switch event {
        case .authStateChanged(let state): return "auth \(state)"
        case .chatPositionChanged: return "chat"
        case .clientGenerationChanged: return "generation"
        default: return "other"
        }
    }

    // MARK: - Helpers

    /// `consumesEvents: false` keeps the app's own event loop from starting,
    /// so a test can hand it the stream's events one at a time.
    private func makeApp(consumesEvents: Bool = true) -> (AppState, MockTelegramService) {
        let service = MockTelegramService()
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        if !consumesEvents {
            // startEventLoop() leaves a consumer that exists alone.
            app.eventTask = Task {}
        }
        apps.append(app)
        return (app, service)
    }

    /// Lets the main actor run until `condition` holds. A condition that never
    /// does fails the assertion that follows it, not this wait.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
