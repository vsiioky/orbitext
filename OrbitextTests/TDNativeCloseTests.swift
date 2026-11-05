import Synchronization
import XCTest
@testable import OrbitextWatch

final class TDNativeCloseTests: XCTestCase {
    func testCloseOkDoesNotReleaseWaiterBeforeTerminalUpdate() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        let completed = CloseTestCounter()
        let stopping = Task {
            try await wrapper.stopAndWait(timeout: .seconds(2))
            completed.increment()
        }
        await fulfillment(of: [transport.closeSent], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(completed.value, 0, "close Ok acknowledges the request, not native shutdown")
        XCTAssertFalse(wrapper.isNativeClosed)

        transport.emitClosed()
        try await stopping.value
        XCTAssertTrue(wrapper.isNativeClosed)
        XCTAssertEqual(completed.value, 1)
    }

    func testCloseTimeoutKeepsReceiverAvailableForRetry() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        do {
            try await wrapper.stopAndWait(timeout: .milliseconds(50))
            XCTFail("Missing terminal update must time out")
        } catch TDError.timeout {
            // Expected: request acknowledgement alone is insufficient.
        }
        XCTAssertFalse(wrapper.isNativeClosed)

        transport.emitClosed()
        try await wrapper.stopAndWait(timeout: .seconds(1))

        XCTAssertTrue(wrapper.isNativeClosed)
        XCTAssertEqual(transport.closeRequestCount, 1)
    }

    func testCancelledCloseDoesNotCancelOtherCloseWaiter() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        let cancelled = Task { try await wrapper.stopAndWait(timeout: .seconds(2)) }
        let surviving = Task { try await wrapper.stopAndWait(timeout: .seconds(2)) }
        await fulfillment(of: [transport.closeSent], timeout: 1)

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // The other caller still owns its independent wait.
        }
        XCTAssertFalse(wrapper.isNativeClosed)

        transport.emitClosed()
        try await surviving.value
        XCTAssertTrue(wrapper.isNativeClosed)
    }

    func testPausedReceiverResumesToObserveTerminalClose() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        wrapper.startReceiveLoop { _ in }
        wrapper.pause()
        let stopping = Task { try await wrapper.stopAndWait(timeout: .seconds(2)) }
        await fulfillment(of: [transport.closeSent], timeout: 1)

        transport.emitClosed()
        try await stopping.value

        XCTAssertTrue(wrapper.isNativeClosed)
        XCTAssertFalse(wrapper.isPaused)
    }

    func testStopWithoutReceiverCanLaterAwaitNativeClose() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        wrapper.stop()
        transport.emitClosed()

        try await wrapper.stopAndWait(timeout: .seconds(1))

        XCTAssertTrue(wrapper.isNativeClosed)
        XCTAssertEqual(transport.closeRequestCount, 1)
    }

    func testNonblockingStopThenWaitKeepsASingleReceiver() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        wrapper.startReceiveLoop { _ in }
        await fulfillment(of: [transport.receiveStarted], timeout: 1)
        wrapper.stop()
        let stopping = Task { try await wrapper.stopAndWait(timeout: .seconds(2)) }
        await fulfillment(of: [transport.closeSent], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.maximumConcurrentReceives, 1,
                       "A cancelled old receiver must not race a replacement for the terminal update")
        transport.emitClosed()
        try await stopping.value
        XCTAssertTrue(wrapper.isNativeClosed)
    }

    func testCloseWaitsForTerminalUpdateCallbackToFinish() async throws {
        let transport = CloseTestTransport()
        let wrapper = transport.wrapper()
        let callbackEntered = expectation(description: "terminal callback entered")
        let releaseCallback = DispatchSemaphore(value: 0)
        let completed = CloseTestCounter()
        wrapper.startReceiveLoop { update in
            guard update["@type"] as? String == "updateAuthorizationState" else { return }
            callbackEntered.fulfill()
            releaseCallback.wait()
        }
        let stopping = Task {
            try await wrapper.stopAndWait(timeout: .seconds(2))
            completed.increment()
        }
        defer { releaseCallback.signal() }
        await fulfillment(of: [transport.closeSent], timeout: 1)
        transport.emitClosed()
        await fulfillment(of: [callbackEntered], timeout: 1)
        // Give a completed receive task enough time to return independently.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(completed.value, 0, "Old callbacks must drain before a replacement can be installed")
        releaseCallback.signal()
        try await stopping.value
        XCTAssertEqual(completed.value, 1)
    }

    func testTerminalCallbackTimeoutPreservesSessionUntilDrainRetry() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let callbackEntered = expectation(description: "terminal callback entered")
        let releaseCallback = DispatchSemaphore(value: 0)
        fixture.wrapper.startReceiveLoop { update in
            guard update["@type"] as? String == "updateAuthorizationState" else { return }
            callbackEntered.fulfill()
            releaseCallback.wait()
        }
        defer { releaseCallback.signal() }
        let cleanup = Task { try await fixture.service.completeLocalLogoutCleanup() }
        await fulfillment(of: [fixture.transport.closeSent], timeout: 1)
        fixture.transport.emitClosed()
        await fulfillment(of: [callbackEntered], timeout: 1)
        do {
            try await cleanup.value
            XCTFail("The close deadline must also bound callback drain")
        } catch TDError.timeout {}
        XCTAssertTrue(fixture.wrapper.isNativeClosed)
        fixture.assertPreserved()

        releaseCallback.signal()
        try await fixture.service.completeLocalLogoutCleanup()
        XCTAssertEqual(fixture.keyRemovals.value, 1)
        XCTAssertNil(fixture.service.getTD())
    }

    func testCancellationDuringTerminalCallbackPreservesSessionUntilDrainRetry() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        let callbackEntered = expectation(description: "terminal callback entered")
        let releaseCallback = DispatchSemaphore(value: 0)
        fixture.wrapper.startReceiveLoop { update in
            guard update["@type"] as? String == "updateAuthorizationState" else { return }
            callbackEntered.fulfill()
            releaseCallback.wait()
        }
        defer { releaseCallback.signal() }
        let cleanup = Task { try await fixture.service.completeLocalLogoutCleanup() }
        await fulfillment(of: [fixture.transport.closeSent], timeout: 1)
        fixture.transport.emitClosed()
        await fulfillment(of: [callbackEntered], timeout: 1)
        cleanup.cancel()
        do {
            try await cleanup.value
            XCTFail("Callback drain must respond to cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(fixture.wrapper.isNativeClosed)
        fixture.assertPreserved()

        releaseCallback.signal()
        try await fixture.service.completeLocalLogoutCleanup()
        XCTAssertEqual(fixture.keyRemovals.value, 1)
        XCTAssertNil(fixture.service.getTD())
    }

    func testLateClosedCallbackFromReplacedClientIsIgnored() throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let oldClient = CloseTestTransport().wrapper()

        fixture.service.handleUpdate([
            "@type": "updateAuthorizationState",
            "authorization_state": ["@type": "authorizationStateClosed"]
        ], from: oldClient)

        fixture.assertPreserved()
        XCTAssertEqual(fixture.service.auth.restartCount, 0)
    }

    func testLogoutTimeoutPreservesDatabaseKeyCachesAndClientUntilRetry() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        do {
            try await fixture.service.completeLocalLogoutCleanup()
            XCTFail("Cleanup must reject an unconfirmed close")
        } catch TDError.timeout {
            // No destructive step is permitted after this failure.
        }
        fixture.assertPreserved()

        fixture.transport.emitClosed()
        try await fixture.service.completeLocalLogoutCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertEqual(fixture.keyRemovals.value, 1)
        XCTAssertNil(fixture.service.getTD())
        XCTAssertTrue(fixture.service.auth.stagedDatabaseKey.isEmpty)
        XCTAssertEqual(fixture.service.userCache.count, 0)
        // Nothing evicts the chat mirror any more; logout must empty it.
        XCTAssertEqual(fixture.service.chatCache.count, 0)
        XCTAssertEqual(fixture.service.auth.observedState, .waitPhoneNumber)
    }

    func testCancelledLogoutPreservesDatabaseKeyAndClient() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        let cleanup = Task { try await fixture.service.resetLocalSession() }
        await fulfillment(of: [fixture.transport.closeSent], timeout: 1)

        cleanup.cancel()
        do {
            try await cleanup.value
            XCTFail("Cancelled cleanup must throw")
        } catch is CancellationError {
            // The same retained wrapper can finish safely on a later retry.
        }
        fixture.assertPreserved()

        fixture.transport.emitClosed()
        try await fixture.service.resetLocalSession()
        XCTAssertEqual(fixture.keyRemovals.value, 1)
    }

    /// A wipe that has to be retried leaves a session nobody may treat as
    /// registered for pushes: the same token must register again with the
    /// next ready client instead of being taken for the old registration.
    func testWipeThatCannotConfirmCloseForgetsThePushRegistration() async throws {
        for wipe in ["resetLocalSession", "logout"] {
            let fixture = try CloseTestFixture()
            defer { fixture.removeTemporaryDirectory() }
            fixture.service.push.state.withLock { push in
                push.pendingToken = "01"
                push.registeredToken = "01"
                push.receiverId = 101
            }

            do {
                if wipe == "logout" {
                    try await fixture.service.logout()
                } else {
                    try await fixture.service.resetLocalSession()
                }
                XCTFail("\(wipe) cannot finish before native close is confirmed")
            } catch TDError.timeout {}

            fixture.assertPreserved()
            let push = fixture.service.push.state.withLock {
                (pending: $0.pendingToken, registered: $0.registeredToken, receiver: $0.receiverId)
            }
            XCTAssertEqual(push.pending, "01", "\(wipe): the device token stays for the next sign-in")
            XCTAssertNil(push.registered, "\(wipe): the token still counts as registered")
            XCTAssertNil(push.receiver, "\(wipe): pushes are still matched to the wiped session")
        }
    }

    /// The APNs token belongs to the device, not to the account: the system
    /// hands it over once per process, so a wipe that forgot it would leave
    /// the next account without remote pushes until the app is relaunched.
    func testSignInAfterAWipeRegistersTheDeviceTokenForTheNextAccount() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        fixture.service.push.state.withLock { push in
            push.pendingToken = "01"
            push.registeredToken = "01"
            push.receiverId = 101
            push.isReady = true
        }
        fixture.transport.emitClosed()
        try await fixture.service.completeLocalLogoutCleanup()
        let afterWipe = fixture.service.push.state.withLock {
            (pending: $0.pendingToken, registered: $0.registeredToken, receiver: $0.receiverId, ready: $0.isReady)
        }
        XCTAssertEqual(afterWipe.pending, "01", "The device token belongs to the device and stays")
        XCTAssertNil(afterWipe.registered)
        XCTAssertNil(afterWipe.receiver)
        XCTAssertFalse(afterWipe.ready)

        // The next account signs in on a new client.
        let next = ScriptedTDTransport(clientId: 9102) { request in
            if request["@type"] as? String == "registerDevice" {
                return .result(["@type": "pushReceiverId", "id": 202])
            }
            return .result(["@type": "ok"])
        }
        let nextClient = next.wrapper()
        nextClient.startReceiveLoop { _ in }
        defer { nextClient.stop() }
        fixture.service.installClient(nextClient)
        fixture.service.auth.prepareForNewClient()
        fixture.service.handleAuthUpdate(["@type": "authorizationStateReady"], sourceClient: nextClient)

        try await waitUntil { fixture.service.push.state.withLock { $0.receiverId } == 202 }
        let registrations = next.requests(ofType: "registerDevice")
        XCTAssertEqual(registrations.count, 1, "The new account never registered the device for pushes")
        let token = (registrations.first?["device_token"] as? [String: Any])?["device_token"] as? String
        XCTAssertEqual(token, "01")
    }

    @MainActor
    func testLogoutSignsOutOnServerAndUnregistersPushBeforeWipingLocally() async throws {
        // A long server timeout: answered requests must not wait it out.
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2), logoutServerTimeout: .seconds(10))
        defer { fixture.removeTemporaryDirectory() }
        fixture.transport.answersServerRequests = true
        fixture.wrapper.startReceiveLoop { _ in }
        let app = AppState(service: fixture.service, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
        app.networkMonitor.pause()

        let logout = Task { await app.logout() }
        let closeRequested = await XCTWaiter().fulfillment(of: [fixture.transport.closeSent], timeout: 3)
        guard closeRequested == .completed else {
            logout.cancel()
            return XCTFail("Logout did not reach native close: it ignores server answers or never goes local")
        }
        fixture.transport.emitClosed()
        await logout.value

        XCTAssertEqual(fixture.transport.sentTypes, ["registerDevice", "logOut", "close"],
                       "The session stays active on the server and keeps receiving pushes")
        let token = (fixture.transport.sentRequests.first?["device_token"] as? [String: Any])?["device_token"] as? String
        XCTAssertEqual(token, "", "An empty token unregisters this device")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
    }

    func testOfflineLogoutStillWipesLocallyWithinServerTimeout() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        // Offline or under FLOOD_WAIT: TDLib never answers registerDevice or logOut.
        fixture.wrapper.startReceiveLoop { _ in }
        let start = ContinuousClock.now

        let logout = Task { try await fixture.service.logout() }
        let closeRequested = await XCTWaiter().fulfillment(of: [fixture.transport.closeSent], timeout: 3)
        guard closeRequested == .completed else {
            logout.cancel()
            return XCTFail("Logout hangs on a server that never answers")
        }
        fixture.transport.emitClosed()
        try await logout.value

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(fixture.transport.sentTypes, ["registerDevice", "logOut", "close"],
                       "A slow unregister must not starve logOut")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertNil(fixture.service.getTD())
    }

    func testStaleQRRefreshAfterLoginDoesNotReturnToTheQRScreen() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        // Login completed while a QR refresh request was still in flight.
        fixture.service.auth.observedState = .ready
        let events = Task { [events = fixture.service.events] () -> [TDLibEvent] in
            var collected: [TDLibEvent] = []
            for await event in events { collected.append(event) }
            return collected
        }

        fixture.service.auth.applyQRRefreshResponse([
            "@type": "authorizationStateWaitOtherDeviceConfirmation", "link": "tg://login?token=stale"
        ], from: fixture.wrapper)
        try await Task.sleep(for: .milliseconds(100))
        events.cancel()
        let received = await events.value

        let returnedToQR = received.contains { event in
            if case .authStateChanged(let state) = event { return state == .waitOtherDeviceConfirmation }
            return false
        }
        XCTAssertFalse(returnedToQR,
                       "A stale refresh rolled the signed-in app back to the QR screen")
        XCTAssertEqual(fixture.service.auth.observedState, .ready)
    }

    func testQRRefreshUpdatesTheLinkWhileQRIsShown() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        fixture.service.auth.observedState = .waitOtherDeviceConfirmation
        let firstLink = Task { [events = fixture.service.events] () -> String? in
            for await event in events {
                if case .qrCodeLink(let link) = event { return link }
            }
            return nil
        }

        fixture.service.auth.applyQRRefreshResponse([
            "@type": "authorizationStateWaitOtherDeviceConfirmation", "link": "tg://login?token=fresh"
        ], from: fixture.wrapper)
        let timeout = Task { try? await Task.sleep(for: .seconds(1))
        firstLink.cancel()
        }
        let link = await firstLink.value
        timeout.cancel()

        XCTAssertEqual(link, "tg://login?token=fresh")
    }

    func testRestartCleanupTimeoutPreservesExistingClientAndFiles() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        do {
            try await fixture.service.finishClosedClient(fixture.wrapper, reason: "test restart")
            XCTFail("A restart cannot remove files before the terminal event")
        } catch TDError.timeout {
            // Expected.
        }
        fixture.assertPreserved()

        fixture.transport.emitClosed()
        try await fixture.service.finishClosedClient(fixture.wrapper, reason: "test restart retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertNil(fixture.service.getTD())
    }

    // MARK: - setTdlibParameters belongs to the client that asked for it

    func testParametersCutOffByLogoutAreNotReportedAsInitFailure() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        let events = Task { [events = fixture.service.events] () -> [TDLibEvent] in
            var collected: [TDLibEvent] = []
            for await event in events { collected.append(event) }
            return collected
        }
        fixture.service.handleAuthUpdate(["@type": "authorizationStateWaitTdlibParameters"], sourceClient: fixture.wrapper)
        try await waitUntil { fixture.transport.sentTypes.contains("setTdlibParameters") }

        // Native close abandons the request that is still waiting for its answer.
        fixture.transport.emitClosed()
        try await fixture.service.completeLocalLogoutCleanup()
        try await Task.sleep(for: .milliseconds(200))
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        let errors: [AuthState] = received.compactMap { event in
            if case .authStateChanged(let state) = event, case .error = state { return state }
            return nil
        }
        XCTAssertEqual(errors, [], "A request cut off by our own close is not an initialization failure")
    }

    func testParametersGoToTheClientThatAskedForThem() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let replacementTransport = CloseTestTransport()
        let replacement = replacementTransport.wrapper()

        fixture.service.handleAuthUpdate(["@type": "authorizationStateWaitTdlibParameters"], sourceClient: fixture.wrapper)
        // A replacement client is installed before the sending task first runs.
        fixture.service.session.replaceClientForTesting(replacement)
        try await waitUntil { fixture.transport.sentTypes.contains("setTdlibParameters") }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fixture.transport.sentTypes.contains("setTdlibParameters"))
        XCTAssertEqual(replacementTransport.sentTypes, [],
                       "TDLib rejects a second setTdlibParameters and the app would show an init error")
    }

    /// Answers setTdlibParameters with a TDLib API error after a delay, so a
    /// test can change the current client while the request is in flight.
    private func failingParametersFixture() -> ScriptedServiceFixture {
        ScriptedServiceFixture { request in
            guard request["@type"] as? String == "setTdlibParameters" else { return .result(["@type": "ok"]) }
            return .delayed(0.2, ["@type": "error", "code": 400, "message": "Initialization parameters are needed"])
        }
    }

    private func initErrors(in events: [TDLibEvent]) -> [AuthState] {
        events.compactMap { event in
            if case .authStateChanged(let state) = event, case .error = state { return state }
            return nil
        }
    }

    func testParametersFailureOfTheCurrentClientIsReported() async throws {
        let fixture = failingParametersFixture()
        defer { fixture.finish() }
        let events = collectEvents(of: fixture.service)

        fixture.service.handleAuthUpdate(["@type": "authorizationStateWaitTdlibParameters"], sourceClient: fixture.client)
        try await waitUntil { fixture.transport.methods.contains("setTdlibParameters") }
        try await Task.sleep(for: .milliseconds(500))
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(initErrors(in: received).count, 1, "A real initialization failure must reach the sign-in screen")
        XCTAssertEqual(fixture.service.auth.observedState, initErrors(in: received).first)
    }

    func testParametersFailureOfAReplacedClientIsNotReported() async throws {
        let fixture = failingParametersFixture()
        defer { fixture.finish() }
        let replacement = ScriptedTDTransport(clientId: 9101).wrapper()
        let events = collectEvents(of: fixture.service)

        fixture.service.handleAuthUpdate(["@type": "authorizationStateWaitTdlibParameters"], sourceClient: fixture.client)
        try await waitUntil { fixture.transport.methods.contains("setTdlibParameters") }
        // The next account's client takes over before the old request fails.
        fixture.service.session.replaceClientForTesting(replacement)
        try await Task.sleep(for: .milliseconds(500))
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(initErrors(in: received), [],
                       "An API error of a retired client would show over the next account's sign-in screen")
        if case .error = fixture.service.auth.observedState {
            XCTFail("The retired client's failure became the observed auth state")
        }
    }

    func testAuthStateIsEmittedForTheCurrentClient() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)

        fixture.service.auth.emitAuthState(.waitCode, ifCurrent: fixture.wrapper)
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), ["auth waitCode"])
        XCTAssertEqual(fixture.service.auth.observedState, .waitCode)
    }

    func testAuthStateOfAReplacedClientIsNotEmitted() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)
        let retired = CloseTestTransport().wrapper()

        fixture.service.auth.emitAuthState(.waitCode, ifCurrent: retired)
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), [], "Only the current client may report an auth state")
        XCTAssertEqual(fixture.service.auth.observedState, .ready, "The observed state is not touched either")
    }

    // MARK: - Authorization states are handled one at a time

    /// States arrive from the update queue and from the bootstrap answer. A
    /// state that arrives while another is being handled waits for it, so
    /// the app ends on the state TDLib reported last.
    func testAuthStateWaitsForTheOneBeingHandled() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)
        let (service, client) = (fixture.service, fixture.wrapper)
        let gate = AuthHandlerGate(on: service.auth)
        let handled = Mutex<[String]>([])

        // The first state stops in its handler, past the check of its client.
        DispatchQueue.global().async {
            service.handleAuthUpdate(["@type": "authorizationStateWaitPhoneNumber"], sourceClient: client)
            handled.withLock { $0.append("waitPhoneNumber") }
        }
        try await waitUntil { gate.isHolding }
        XCTAssertTrue(gate.isHolding, "The first state never reached its handler")

        DispatchQueue.global().async {
            service.handleAuthUpdate(["@type": "authorizationStateWaitCode"], sourceClient: client)
            handled.withLock { $0.append("waitCode") }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(handled.withLock { $0 }, [],
                       "A later state was handled while an earlier one was still being handled")

        gate.letGo()
        try await waitUntil { handled.withLock { $0.count } == 2 }
        service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(handled.withLock { $0 }, ["waitPhoneNumber", "waitCode"])
        XCTAssertEqual(received.map(Self.label), ["auth waitPhoneNumber", "auth waitCode"])
        XCTAssertEqual(service.auth.observedState, .waitCode, "The app ended on a state TDLib had left")
    }

    /// A state handled for a client that is retired before the state is
    /// reported belongs to the old session: it must not follow the marker.
    func testAuthStateOfAClientRetiredWhileItIsHandledIsNotReported() async throws {
        let fixture = try CloseTestFixture()
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)
        let (service, client) = (fixture.service, fixture.wrapper)
        let gate = AuthHandlerGate(on: service.auth)
        let handled = Mutex(false)

        DispatchQueue.global().async {
            service.handleAuthUpdate(["@type": "authorizationStateWaitPhoneNumber"], sourceClient: client)
            handled.withLock { $0 = true }
        }
        // The handler has checked the client and is about to act on the state.
        try await waitUntil { gate.isHolding }
        XCTAssertTrue(gate.isHolding, "The state never reached its handler: the in-flight path is not tested")
        service.session.retire()
        service.installClient(CloseTestTransport().wrapper())
        gate.letGo()
        try await waitUntil { handled.withLock { $0 } }
        XCTAssertTrue(handled.withLock { $0 }, "The handler did not finish")
        service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), ["generation 1", "generation 2", "chatListSessionStarted"],
                       "A state of the retired client reached the next session")
        XCTAssertEqual(service.auth.observedState, .ready)
    }

    // MARK: - Events of a logged-out client

    @MainActor
    func testStaleEventsOfALoggedOutClientDoNotRepopulateTheNextAccount() async throws {
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
        defer { ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats") }
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2), logoutServerTimeout: .seconds(10))
        defer { fixture.removeTemporaryDirectory() }
        fixture.transport.answersServerRequests = true
        fixture.wrapper.startReceiveLoop { _ in }
        let app = AppState(service: fixture.service, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
        app.networkMonitor.pause()
        // Not initialize(): the events below stay queued, as when the
        // consumer is a step behind the logout.
        let oldAccountChat = ChatInfo(id: 501, title: "Old account", lastMessage: nil, unreadCount: 0,
                                      isGroup: false, isMuted: false, order: 9)
        fixture.service.emit(.authStateChanged(.closing))
        fixture.service.emit(.chatPositionChanged(.init(
            chat: oldAccountChat,
            positions: [ChatListPosition(list: .main, order: 9, isPinned: false)],
            source: .explicitPosition
        )))

        let logout = Task { await app.logout() }
        let closeRequested = await XCTWaiter().fulfillment(of: [fixture.transport.closeSent], timeout: 3)
        guard closeRequested == .completed else {
            logout.cancel()
            return XCTFail("Logout did not reach native close")
        }
        fixture.transport.emitClosed()
        await logout.value
        fixture.service.session.finishEventsForTesting()
        // What the screen shows after each event: the cleanup's own
        // waitPhoneNumber comes last and would hide a stale state before it.
        var shownStates: [AuthState] = []
        for await event in fixture.service.events {
            app.handleEvent(event)
            shownStates.append(app.authManager.authState)
        }

        XCTAssertTrue(app.chatRepository.chats.isEmpty, "A late update of the old account repopulated the list")
        app.chatRepository.chatListCache.flush()
        XCTAssertNil(app.chatRepository.chatListCache.load()?.first { $0.id == 501 },
                     "The old account's chat reached the cache the next sign-in restores")
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
        XCTAssertFalse(shownStates.isEmpty)
        XCTAssertTrue(shownStates.allSatisfy { $0 == .waitPhoneNumber },
                      "A late state of the old client flashed over the sign-in screen: \(shownStates)")
    }

    // MARK: - Client generations mark the event stream

    func testLogoutCleanupRetiresTheClientGenerationBeforeReportingSignedOut() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)
        let chat = ChatInfo(id: 12, title: "Old account", lastMessage: nil, unreadCount: 0,
                            isGroup: false, isMuted: false, order: 1)
        fixture.service.emit(.chatUpdated(chat))

        fixture.transport.emitClosed()
        try await fixture.service.completeLocalLogoutCleanup()
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        // The old client's events come first, then the retirement, then the
        // state the next sign-in starts from.
        XCTAssertEqual(received.map(Self.label), ["chatUpdated", "generation 1", "auth waitPhoneNumber"])
        XCTAssertEqual(fixture.service.clientGeneration, TDClientGeneration.initial.next())
    }

    func testInstallingAClientStartsAGenerationBeforeItsChatListSession() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TDLibService(databaseDirectory: directory, removeDatabaseKey: {})
        let events = collectEvents(of: service)
        let transport = CloseTestTransport()
        XCTAssertEqual(service.clientGeneration, .initial)

        service.installClient(transport.wrapper())
        service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), ["generation 1", "chatListSessionStarted"])
        XCTAssertEqual(service.clientGeneration, TDClientGeneration.initial.next())
    }

    func testCleanupWithoutAClientKeepsTheGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TDLibService(databaseDirectory: directory, removeDatabaseKey: {})
        let events = collectEvents(of: service)

        try await service.completeLocalLogoutCleanup()
        service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), ["auth waitPhoneNumber"], "Nothing was retired, so no marker")
        XCTAssertEqual(service.clientGeneration, .initial)
    }

    func testRestartRetiresTheOldClientBeforeInstallingTheNext() async throws {
        let fixture = try CloseTestFixture(closeTimeout: .seconds(2))
        defer { fixture.removeTemporaryDirectory() }
        let events = collectEvents(of: fixture.service)
        fixture.transport.emitClosed()

        try await fixture.service.finishClosedClient(fixture.wrapper, reason: "test restart")
        fixture.service.installClient(CloseTestTransport().wrapper())
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received.map(Self.label), ["generation 1", "generation 2", "chatListSessionStarted"])
        XCTAssertEqual(fixture.service.clientGeneration.rawValue, 2)
    }

    private func collectEvents(of service: TDLibService) -> Task<[TDLibEvent], Never> {
        Task { [events = service.events] in
            var collected: [TDLibEvent] = []
            for await event in events { collected.append(event) }
            return collected
        }
    }

    private static func label(_ event: TDLibEvent) -> String {
        switch event {
        case .clientGenerationChanged(let generation): return "generation \(generation.rawValue)"
        case .chatListSessionStarted: return "chatListSessionStarted"
        case .authStateChanged(let state): return "auth \(state)"
        case .chatUpdated: return "chatUpdated"
        default: return "other"
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Where the receive loop runs and whether td_execute waits for it.
final class TDReceiveThreadTests: XCTestCase {
    func testReceiveLoopRunsOnItsOwnThreadOutsideTheCooperativePool() async {
        let threadName = CloseTestValue<String>()
        let wrapper = TDJsonWrapper(clientId: 321, send: { _, _ in }, receive: { timeout in
            threadName.set(Thread.current.name ?? "")
            Thread.sleep(forTimeInterval: min(timeout, 0.01))
            return nil
        })

        wrapper.startReceiveLoop { _ in }
        let deadline = ContinuousClock.now + .seconds(1)
        while threadName.value == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The watch has two cooperative threads; a blocking td_receive must not hold one.
        XCTAssertEqual(threadName.value, "com.orbitext.td-receive")
    }

    func testReceiveThreadDoesNotKeepParsedUpdatesAlive() async throws {
        let eventCount = 10_000
        let payload = #"{"@type":"updateOption","@client_id":654,"name":"probe","value":{"@type":"optionValueString","value":""#
            + String(repeating: "x", count: 2_000) + #""}}"#
        let delivered = CloseTestCounter()
        let handled = CloseTestCounter()
        let wrapper = TDJsonWrapper(clientId: 654, send: { _, _ in }, receive: { _ in
            guard delivered.value < eventCount else {
                Thread.sleep(forTimeInterval: 0.01)
                return nil
            }
            delivered.increment()
            return payload
        })
        let before = Self.mallocBytesInUse()

        wrapper.startReceiveLoop { _ in handled.increment() }
        let deadline = ContinuousClock.now + .seconds(10)
        while handled.value < eventCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        wrapper.pause()
        try await Task.sleep(for: .milliseconds(50))
        let grownMB = Double(Self.mallocBytesInUse() - before) / 1_048_576

        XCTAssertEqual(handled.value, eventCount)
        // Without a pool per event this thread kept about 4 KB per update.
        XCTAssertLessThan(grownMB, 8, "Parsed updates stay autoreleased on the receive thread")
    }

    private static func mallocBytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func testExecuteDoesNotWaitForABlockedReceive() async throws {
        let wrapper = TDJsonWrapper()
        wrapper.startReceiveLoop { _ in }
        // Let the receiver settle into td_receive(1.0) on an idle client.
        try await Task.sleep(for: .milliseconds(200))

        let start = Date()
        let result = wrapper.execute(["@type": "getTextEntities", "text": "@telegram"])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result?["@type"] as? String, "textEntities")
        XCTAssertLessThan(elapsed, 0.3, "td_execute waited for the receive lock")
        // Close the native client and its receiver before other tests run.
        try await wrapper.stopAndWait()
    }
}

private final class CloseTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

private final class CloseTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Fake tdjson transport: close returns Ok, while the terminal update is held
/// until the test releases it. It performs no native TDLib or filesystem work.
private final class CloseTestTransport: @unchecked Sendable {
    let closeSent = XCTestExpectation(description: "native close requested")
    let receiveStarted = XCTestExpectation(description: "receive loop entered transport")
    private let condition = NSCondition()
    private var responses: [String] = []
    private var closeCount = 0
    private var receiveCount = 0
    private var receiveCalls = 0
    private var terminalEnqueued = false
    private var maximumReceives = 0
    private var sent: [[String: Any]] = []
    private var answersServer = false
    var closeRequestCount: Int { condition.withLock { closeCount } }
    var maximumConcurrentReceives: Int { condition.withLock { maximumReceives } }
    var sentTypes: [String] { condition.withLock { sent.compactMap { $0["@type"] as? String } } }
    var sentRequests: [[String: Any]] { condition.withLock { sent } }
    /// Online: registerDevice and logOut get an `ok`. Offline (default): no answer.
    var answersServerRequests: Bool {
        get { condition.withLock { answersServer } }
        set { condition.withLock { answersServer = newValue } }
    }

    func wrapper() -> TDJsonWrapper {
        TDJsonWrapper(clientId: 123, send: { [self] _, request in send(request) },
                      receive: { [self] timeout in receive(timeout) })
    }

    private func send(_ json: String) {
        guard let data = json.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = request["@type"] as? String
        let answers = condition.withLock { () -> Bool in
            sent.append(request)
            return answersServer
        }
        if answers, type == "registerDevice" || type == "logOut" {
            enqueue(["@type": "ok", "@client_id": 123, "@extra": request["@extra"] ?? ""])
        }
        guard type == "close" else { return }
        condition.withLock { closeCount += 1 }
        enqueue(["@type": "ok", "@client_id": 123, "@extra": "close-ack"])
        closeSent.fulfill()
    }

    func emitClosed() {
        enqueue(["@type": "updateAuthorizationState", "@client_id": 123,
                 "authorization_state": ["@type": "authorizationStateClosed"]])
    }

    private func enqueue(_ response: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: response)
        condition.lock()
        if response["@type"] as? String == "updateAuthorizationState" { terminalEnqueued = true }
        responses.append(String(decoding: data, as: UTF8.self))
        condition.broadcast()
        condition.unlock()
    }

    private func receive(_ timeout: Double) -> String? {
        condition.lock()
        receiveCount += 1
        receiveCalls += 1
        maximumReceives = max(maximumReceives, receiveCount)
        if receiveCalls == 1 { receiveStarted.fulfill() }
        defer {
            receiveCount -= 1
            condition.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while responses.isEmpty {
            if terminalEnqueued || timeout == 0 || !condition.wait(until: deadline) { return nil }
        }
        return responses.removeFirst()
    }
}

private struct CloseTestFixture {
    let directory: URL
    let marker: URL
    let service: TDLibService
    let transport: CloseTestTransport
    let wrapper: TDJsonWrapper
    let keyRemovals: CloseTestCounter

    init(closeTimeout: Duration = .milliseconds(100), logoutServerTimeout: Duration = .milliseconds(200)) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-close-\(UUID().uuidString)")
        marker = directory.appendingPathComponent("db-marker")
        let keyRemovals = CloseTestCounter()
        self.keyRemovals = keyRemovals
        service = TDLibService(databaseDirectory: directory, nativeCloseTimeout: closeTimeout,
                               logoutServerTimeout: logoutServerTimeout,
                               removeDatabaseKey: { keyRemovals.increment() })
        transport = CloseTestTransport()
        wrapper = transport.wrapper()
        service.session.replaceClientForTesting(wrapper)
        service.auth.stagedDatabaseKey = Data([7, 8, 9])
        service.auth.observedState = .ready
        service.userCache.set(12, .sample(id: 12, firstName: "Cached user"))
        service.chatCache.set(12, ChatInfo(id: 12, title: "Cached chat", lastMessage: nil, unreadCount: 0,
                                           isGroup: false, isMuted: false, order: 1))
        try Data("retained database".utf8).write(to: marker)
    }

    func assertPreserved(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), file: file, line: line)
        XCTAssertEqual(keyRemovals.value, 0, file: file, line: line)
        XCTAssertEqual(service.auth.stagedDatabaseKey, Data([7, 8, 9]), file: file, line: line)
        XCTAssertTrue(service.getTD() === wrapper, file: file, line: line)
        XCTAssertEqual(service.userCache.count, 1, file: file, line: line)
        XCTAssertEqual(service.chatCache.count, 1, file: file, line: line)
        XCTAssertEqual(service.auth.observedState, .ready, file: file, line: line)
        XCTAssertFalse(service.isClientTransitionInProgress, file: file, line: line)
    }

    func removeTemporaryDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
