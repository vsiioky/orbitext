import XCTest
@testable import OrbitextWatch

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testSceneActivationResumesTheTransportAndMirrorsTheForeground() {
        let rig = Rig()

        rig.coordinator.sceneDidBecomeActive()

        XCTAssertEqual(rig.service.resumeCallCount, 1)
        XCTAssertEqual(rig.host.backgroundMirror, [false])
        XCTAssertEqual(rig.coordinator.state.isSceneActive, true)
    }

    func testEnteringTheBackgroundWithoutLeasesSuspendsOnce() {
        let rig = Rig()
        rig.coordinator.sceneDidBecomeActive()

        rig.coordinator.sceneDidEnterBackground()

        XCTAssertEqual(rig.service.suspendCallCount, 1)
        XCTAssertEqual(rig.host.backgroundMirror, [false, true])
    }

    // MARK: - Leases

    func testLeaseKeepsTheTransportAwakeAfterTheSceneLeaves() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.coordinator.sceneDidBecomeActive()
        let gate = StartGate()
        let refresh = Task { await rig.coordinator.withLease(.backgroundRefresh, policy: .remotePush) { await gate.pass() } }
        await gate.waitUntilEntered()

        rig.coordinator.sceneDidEnterBackground()
        XCTAssertEqual(rig.service.suspendCallCount, 0, "A refresh is still using the client")
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 1))

        gate.release()
        _ = await refresh.value
        XCTAssertEqual(rig.service.suspendCallCount, 1, "The last owner puts the transport to sleep")
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 0))
    }

    func testEarlierLeaseDoesNotSuspendWhileAnotherIsHeld() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        let pushGate = StartGate()
        let refreshGate = StartGate()
        let push = Task { await rig.coordinator.withLease(.remotePush, policy: .remotePush) { await pushGate.pass() } }
        let refresh = Task { await rig.coordinator.withLease(.backgroundRefresh, policy: .remotePush) { await refreshGate.pass() } }
        await pushGate.waitUntilEntered()
        await refreshGate.waitUntilEntered()

        pushGate.release()
        _ = await push.value
        XCTAssertEqual(rig.service.suspendCallCount, 0)

        refreshGate.release()
        _ = await refresh.value
        XCTAssertEqual(rig.service.suspendCallCount, 1)
    }

    func testActiveSceneKeepsTheTransportWhenALeaseEnds() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.coordinator.sceneDidBecomeActive()

        _ = await rig.coordinator.withLease(.remotePush, policy: .remotePush) {}

        XCTAssertEqual(rig.service.suspendCallCount, 0)
        XCTAssertEqual(rig.host.backgroundMirror, [false, false], "The scene is active, so the lease is not background")
    }

    func testPinnedTransportIsNotSuspended() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.host.isTransportPinned = true

        _ = await rig.coordinator.withLease(.remotePush, policy: .remotePush) {}
        rig.coordinator.sceneDidEnterBackground()

        XCTAssertEqual(rig.service.suspendCallCount, 0, "Voice playback keeps the client awake")
    }

    func testLeaseMarksTheRepositoryAsBackgroundUntilTheSceneIsActive() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()

        _ = await rig.coordinator.withLease(.notificationReply, policy: .remotePush) {}

        XCTAssertEqual(rig.host.backgroundMirror, [true])
    }

    func testLeaseIsHeldForTheWholeBodyAndReleasedAfter() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        var leasesInBody = -1
        var suspendsInBody = -1

        let outcome = await rig.coordinator.withLease(.remotePush, policy: .remotePush) { () -> String in
            leasesInBody = rig.coordinator.state.leases.count
            suspendsInBody = rig.service.suspendCallCount
            return "result"
        }

        XCTAssertEqual(outcome, .ran("result"))
        XCTAssertEqual(leasesInBody, 1)
        XCTAssertEqual(suspendsInBody, 0)
        XCTAssertTrue(rig.coordinator.state.leases.isEmpty)
        XCTAssertEqual(rig.service.suspendCallCount, 1, "The scene is inactive, so the last lease puts the transport to sleep")
    }

    // MARK: - Network monitor

    func testSceneActivationStartsTheNetworkMonitorAndIdleBackgroundStopsIt() {
        let rig = Rig()
        addTeardownBlock { @MainActor in rig.networkMonitor.pause() }
        XCTAssertFalse(rig.networkMonitor.isMonitoring)

        rig.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(rig.networkMonitor.isMonitoring)

        rig.coordinator.sceneDidEnterBackground()
        XCTAssertFalse(rig.networkMonitor.isMonitoring, "Nothing needs the path monitor in an idle background")
    }

    func testNetworkMonitorKeepsRunningWhileALeaseOrAPinNeedsTheTransport() async {
        let rig = Rig()
        addTeardownBlock { @MainActor in rig.networkMonitor.pause() }
        rig.coordinator.assumeStarted()
        rig.coordinator.sceneDidBecomeActive()
        let gate = StartGate()
        let refresh = Task { await rig.coordinator.withLease(.backgroundRefresh, policy: .remotePush) { await gate.pass() } }
        await gate.waitUntilEntered()

        rig.coordinator.sceneDidEnterBackground()
        XCTAssertTrue(rig.networkMonitor.isMonitoring, "A refresh in flight still needs the path")

        gate.release()
        _ = await refresh.value
        XCTAssertFalse(rig.networkMonitor.isMonitoring, "The last owner stops it")

        rig.coordinator.sceneDidBecomeActive()
        rig.host.isTransportPinned = true
        rig.coordinator.sceneDidEnterBackground()
        XCTAssertTrue(rig.networkMonitor.isMonitoring, "Voice playback keeps the path monitor too")
    }

    // MARK: - Session transitions

    func testSceneLeavingDuringATransitionSuspendsWhenItEnds() {
        let rig = Rig()
        rig.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(rig.coordinator.beginTransition(.loggingOut))

        rig.coordinator.sceneDidEnterBackground()
        XCTAssertEqual(rig.service.suspendCallCount, 0, "The logout still needs the server's answers")

        rig.coordinator.endTransition(.loggingOut)
        XCTAssertEqual(rig.service.suspendCallCount, 1, "Nobody else would put the transport to sleep")
    }

    func testEndingATransitionWhileTheSceneIsActiveSuspendsNothing() {
        let rig = Rig()
        rig.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(rig.coordinator.beginTransition(.resetting))

        rig.coordinator.endTransition(.resetting)

        XCTAssertEqual(rig.service.suspendCallCount, 0)
    }

    func testEndingATransitionKeepsTheTransportForALeaseAndAPin() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        let gate = StartGate()
        let refresh = Task { await rig.coordinator.withLease(.backgroundRefresh, policy: .remotePush) { await gate.pass() } }
        await gate.waitUntilEntered()
        XCTAssertTrue(rig.coordinator.beginTransition(.loggingOut))

        rig.coordinator.endTransition(.loggingOut)
        XCTAssertEqual(rig.service.suspendCallCount, 0, "A refresh is still using the client")

        gate.release()
        _ = await refresh.value
        XCTAssertEqual(rig.service.suspendCallCount, 1)

        rig.host.isTransportPinned = true
        XCTAssertTrue(rig.coordinator.beginTransition(.resetting))
        rig.coordinator.endTransition(.resetting)
        XCTAssertEqual(rig.service.suspendCallCount, 1, "Voice playback keeps the client awake")
    }

    func testEndingAnotherTransitionSuspendsNothing() {
        let rig = Rig()
        XCTAssertTrue(rig.coordinator.beginTransition(.loggingOut))
        rig.coordinator.sceneDidEnterBackground()
        XCTAssertEqual(rig.service.suspendCallCount, 0)

        rig.coordinator.endTransition(.resetting)

        XCTAssertEqual(rig.service.suspendCallCount, 0, "The logout is still running")
    }

    // MARK: - Lease policies

    func testPushPolicySkipsWhenNotStartedWithoutResuming() async {
        let rig = Rig()

        let outcome = await rig.coordinator.withLease(.remotePush, policy: .remotePush) { "ran" }

        XCTAssertEqual(outcome, .skipped(.notStarted), "A push never cold-starts the client")
        XCTAssertEqual(rig.service.resumeCallCount, 0)
        XCTAssertEqual(rig.service.startCallCount, 0)
        XCTAssertEqual(rig.host.backgroundMirror, [true])
        XCTAssertEqual(rig.service.suspendCallCount, 1)
    }

    func testPushPolicyRunsBeforeTheAccountIsReady() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .idle

        let outcome = await rig.coordinator.withLease(.remotePush, policy: .remotePush) { "ran" }

        XCTAssertEqual(outcome, .ran("ran"))
        XCTAssertEqual(rig.service.resumeCallCount, 1)
    }

    func testRefreshPolicySkipsBeforeResumeWhenNotAuthorized() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .waitPhoneNumber

        let outcome = await rig.coordinator.withLease(.backgroundRefresh, policy: .backgroundRefresh) { "ran" }

        XCTAssertEqual(outcome, .skipped(.notAuthorized))
        XCTAssertEqual(rig.service.resumeCallCount, 0)
    }

    func testRefreshPolicyRunsOnceAuthorized() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .ready

        let outcome = await rig.coordinator.withLease(.backgroundRefresh, policy: .backgroundRefresh) { "ran" }

        XCTAssertEqual(outcome, .ran("ran"))
        XCTAssertEqual(rig.service.resumeCallCount, 1)
    }

    func testNotificationPolicyColdStartsResumesAndWaitsForReady() async {
        let rig = Rig()
        let becomesReady = Task {
            try? await Task.sleep(for: .milliseconds(120))
            rig.authManager.authState = .ready
        }

        let outcome = await rig.coordinator.withLease(.notificationReply, policy: .notificationAction(readyTimeout: 2)) { "ran" }
        await becomesReady.value

        XCTAssertEqual(outcome, .ran("ran"))
        XCTAssertEqual(rig.service.startCallCount, 1)
        XCTAssertEqual(rig.host.prepareCallCount, 1)
        XCTAssertGreaterThanOrEqual(rig.service.resumeCallCount, 1, "The receive loop must run to answer the request")
    }

    func testNotificationPolicyReportsSignedOut() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .waitPhoneNumber

        let outcome = await rig.coordinator.withLease(.notificationReply, policy: .notificationAction(readyTimeout: 2)) { "ran" }

        XCTAssertEqual(outcome, .skipped(.signedOut))
        XCTAssertTrue(rig.coordinator.state.leases.isEmpty)
    }

    func testNotificationPolicyReportsATimeoutWhileTheClientIsNotReady() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .idle

        let outcome = await rig.coordinator.withLease(.notificationReply, policy: .notificationAction(readyTimeout: 0.05)) { "ran" }

        XCTAssertEqual(outcome, .skipped(.timedOut))
    }

    func testCancelledCallerSkipsPushBeforeTakingALease() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()

        let push = Task { await rig.coordinator.withLease(.remotePush, policy: .remotePush) { "ran" } }
        push.cancel()
        let outcome = await push.value

        XCTAssertEqual(outcome, .skipped(.cancelled))
        XCTAssertEqual(rig.host.backgroundMirror, [], "No lease was taken")
        XCTAssertEqual(rig.service.resumeCallCount, 0)
        XCTAssertEqual(rig.service.suspendCallCount, 0)
    }

    func testCancellationWhileStartingSkipsBeforeResuming() async {
        let rig = Rig()
        let gate = StartGate()
        rig.host.prepareGate = gate
        let policy = LeasePolicy(startsClient: true, requiresAuthorization: false,
                                 skipsWhenCancelled: true, authorizationTimeout: nil)

        let caller = Task { await rig.coordinator.withLease(.remotePush, policy: policy) { "ran" } }
        await gate.waitUntilEntered()
        caller.cancel()
        gate.release()
        let outcome = await caller.value

        XCTAssertEqual(outcome, .skipped(.cancelled), "The system gave up on this callback while the client was starting")
        XCTAssertEqual(rig.service.resumeCallCount, 0)
        XCTAssertTrue(rig.coordinator.state.leases.isEmpty)
    }

    func testNotificationPolicyRunsForACancelledCallerWhenAlreadyReady() async {
        // Today's behavior: watchOS cancelling an action that runs long does
        // not drop the dictated reply, and the account is ready.
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .ready

        let action = Task { await rig.coordinator.withLease(.notificationReply, policy: .notificationAction(readyTimeout: 2)) { "ran" } }
        action.cancel()
        let outcome = await action.value

        XCTAssertEqual(outcome, .ran("ran"))
    }

    func testNotificationPolicyReportsACancelledWaitForReady() async {
        let rig = Rig()
        rig.coordinator.assumeStarted()
        rig.authManager.authState = .idle

        let action = Task { await rig.coordinator.withLease(.notificationReply, policy: .notificationAction(readyTimeout: 5)) { "ran" } }
        try? await Task.sleep(for: .milliseconds(30))
        action.cancel()
        let outcome = await action.value

        XCTAssertEqual(outcome, .skipped(.cancelled))
        XCTAssertTrue(rig.coordinator.state.leases.isEmpty)
    }

    // MARK: - Start

    func testEnsureStartedPreparesOnceBeforeTheTransportStarts() async {
        let rig = Rig()

        await rig.coordinator.ensureStarted()
        await rig.coordinator.ensureStarted()

        XCTAssertEqual(rig.host.prepareCallCount, 1)
        XCTAssertEqual(rig.host.startCountWhenPrepared, [0], "The event loop must exist before the client emits")
        XCTAssertEqual(rig.service.startCallCount, 1)
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 0))
    }

    func testConcurrentStartRequestsAwaitTheSameStart() async {
        let rig = Rig()
        let gate = StartGate()
        rig.host.prepareGate = gate
        let first = Task { await rig.coordinator.ensureStarted() }
        await gate.waitUntilEntered()
        XCTAssertEqual(rig.coordinator.phase, .starting)

        var secondReturned = false
        let second = Task {
            await rig.coordinator.ensureStarted()
            secondReturned = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(secondReturned, "A notification action must not run before the client was started")

        gate.release()
        await first.value
        await second.value

        XCTAssertTrue(secondReturned)
        XCTAssertEqual(rig.host.prepareCallCount, 1)
        XCTAssertEqual(rig.service.startCallCount, 1)
    }

    func testCancellingTheCallerDoesNotCutTheStartShort() async {
        let rig = Rig()
        let gate = StartGate()
        rig.host.prepareGate = gate
        let caller = Task { await rig.coordinator.ensureStarted() }
        await gate.waitUntilEntered()

        caller.cancel()
        gate.release()
        await caller.value

        XCTAssertEqual(rig.service.startCallCount, 1, "The start belongs to the coordinator, not to its first caller")
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 0))
    }

    func testResetStartAllowsANewStart() async {
        let rig = Rig()
        await rig.coordinator.ensureStarted()

        rig.coordinator.resetStart()
        XCTAssertEqual(rig.coordinator.phase, .notStarted)
        await rig.coordinator.ensureStarted()

        XCTAssertEqual(rig.service.startCallCount, 2)
        XCTAssertEqual(rig.host.prepareCallCount, 2)
    }

    func testStartResetMeanwhileDoesNotStartTheTransportTwice() async {
        let rig = Rig()
        let gate = StartGate()
        rig.host.prepareGate = gate
        let stale = Task { await rig.coordinator.ensureStarted() }
        await gate.waitUntilEntered()

        rig.host.prepareGate = nil
        rig.coordinator.resetStart()
        await rig.coordinator.ensureStarted()
        gate.release()
        await stale.value

        XCTAssertEqual(rig.service.startCallCount, 1, "The reset start must finish into nothing")
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 0))
    }

    func testSceneLeftDuringTheStartSuspendsTheNewClient() async {
        let rig = Rig()
        let gate = StartGate()
        rig.host.prepareGate = gate
        rig.coordinator.sceneDidBecomeActive()
        let start = Task { await rig.coordinator.ensureStarted() }
        await gate.waitUntilEntered()

        // The wrist drops before the client exists: this suspend reaches no client.
        rig.coordinator.sceneDidEnterBackground()
        let suspendsBeforeTheClient = rig.service.suspendCallCount
        gate.release()
        await start.value

        XCTAssertEqual(rig.service.suspendCallCount, suspendsBeforeTheClient + 1,
                       "The new client would stay online in the background with nobody using it")
    }

    func testAssumedStartIsNotStartedAgain() async {
        let rig = Rig()

        rig.coordinator.assumeStarted()
        await rig.coordinator.ensureStarted()

        XCTAssertEqual(rig.service.startCallCount, 0)
        XCTAssertEqual(rig.host.prepareCallCount, 0)
    }

    func testStartedCoordinatorReportsTheScene() async {
        let rig = Rig()
        await rig.coordinator.ensureStarted()

        rig.coordinator.sceneDidBecomeActive()
        XCTAssertEqual(rig.coordinator.phase, .foreground)

        let gate = StartGate()
        let push = Task { await rig.coordinator.withLease(.remotePush, policy: .remotePush) { await gate.pass() } }
        await gate.waitUntilEntered()
        rig.coordinator.sceneDidEnterBackground()
        XCTAssertEqual(rig.coordinator.phase, .background(leases: 1))
        gate.release()
        _ = await push.value
    }

    // MARK: - Rig

    @MainActor
    private final class StartGate {
        private var entered: CheckedContinuation<Void, Never>?
        private var released: CheckedContinuation<Void, Never>?
        private var isEntered = false
        private var isReleased = false

        /// Called by the code under test; suspends until `release()`.
        func pass() async {
            isEntered = true
            entered?.resume()
            entered = nil
            guard !isReleased else { return }
            await withCheckedContinuation { released = $0 }
        }

        func waitUntilEntered() async {
            guard !isEntered else { return }
            await withCheckedContinuation { entered = $0 }
        }

        func release() {
            isReleased = true
            released?.resume()
            released = nil
        }
    }

    @MainActor
    private final class FakeLifecycleHost: AppLifecycleHost {
        var isTransportPinned = false
        var prepareGate: StartGate?
        weak var service: MockTelegramService?
        private(set) var backgroundMirror: [Bool] = []
        private(set) var prepareCallCount = 0
        private(set) var startCountWhenPrepared: [Int] = []

        func prepareForClientStart() async {
            prepareCallCount += 1
            startCountWhenPrepared.append(service?.startCallCount ?? -1)
            await prepareGate?.pass()
        }

        func transportBackgroundStateDidChange(_ isInBackground: Bool) {
            backgroundMirror.append(isInBackground)
        }
    }

    @MainActor
    private struct Rig {
        let service = MockTelegramService()
        let host = FakeLifecycleHost()
        let authManager: AuthManager
        let networkMonitor = NetworkMonitor(startMonitoring: false)
        let coordinator: AppLifecycleCoordinator

        init() {
            authManager = AuthManager(service: service)
            coordinator = AppLifecycleCoordinator(
                service: service,
                authManager: authManager,
                networkMonitor: networkMonitor
            )
            coordinator.host = host
            host.service = service
        }
    }
}
