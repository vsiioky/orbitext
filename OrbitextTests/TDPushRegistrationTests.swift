import XCTest
@testable import OrbitextWatch

final class TDPushRegistrationTests: XCTestCase {
    func testConcurrentTokenAndReadyTriggersShareOneRegistration() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let callers = (0..<12).map { _ in Task { await fixture.service.updatePushDeviceToken(Data([1])) } }
        await waitUntil { fixture.transport.registrations.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.transport.registrations.count, 1)
        fixture.transport.respond(to: 0, receiver: 101)
        for caller in callers { await caller.value }
        await fixture.service.push.registerPendingIfNeeded()
        XCTAssertEqual(fixture.transport.registrations.count, 1)
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 101)
    }

    func testChangedTokenIgnoresOldSuccessAndRegistersLatestSerially() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let old = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        let latest = Task { await fixture.service.updatePushDeviceToken(Data([2])) }
        await waitUntil { fixture.service.push.state.withLock { $0.pendingToken == "02" } }
        fixture.transport.respond(to: 0, receiver: 101)
        await waitUntil { fixture.transport.registrations.count == 2 }
        XCTAssertNil(fixture.service.push.state.withLock { $0.receiverId })
        XCTAssertEqual(fixture.transport.registrationTokens, ["01", "02"])
        fixture.transport.respond(to: 1, receiver: 202)
        await old.value
        await latest.value
        XCTAssertEqual(fixture.service.push.state.withLock { $0.registeredToken }, "02")
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 202)
    }

    func testFailedRegistrationKeepsTokenForExplicitRetry() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let first = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        fixture.transport.respond(to: 0, error: (400, "TEST_REJECTED"))
        await first.value
        XCTAssertNil(fixture.service.push.state.withLock { $0.registeredToken })
        XCTAssertNil(fixture.service.push.state.withLock { $0.receiverId })
        XCTAssertEqual(fixture.service.push.state.withLock { $0.pendingToken }, "01")
        let retry = Task { await fixture.service.push.registerPendingIfNeeded() }
        await waitUntil { fixture.transport.registrations.count == 2 }
        fixture.transport.respond(to: 1, receiver: 101)
        await retry.value
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 101)
    }

    func testFullNativeAndFloodWaitDeadlinePreventsEarlyRetryAndAllowsChatRequests() async throws {
        for error in [(429, "Too Many Requests: retry after 2640"), (420, "FLOOD_WAIT_2640")] {
            let fixture = try PushFixture()
            defer { fixture.cleanup() }
            let registration = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
            await waitUntil { fixture.transport.registrations.count == 1 }
            fixture.transport.respond(to: 0, error: error)
            await waitUntil { fixture.clock.waitingCount == 1 }
            let repeated = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
            let chat = try await fixture.service.throttledSend(["@type": "getChats"])
            XCTAssertEqual(chat["@type"] as? String, "ok")
            XCTAssertNil(fixture.service.currentFloodWaitRemaining(), "Push-only limit must not block the chat UI")
            fixture.clock.advance(seconds: 2639)
            XCTAssertEqual(fixture.transport.registrations.count, 1)
            let remaining = await fixture.service.throttle.remainingBackoff(method: "registerDevice")
            XCTAssertEqual(remaining, .seconds(1))
            fixture.clock.advance(seconds: 1)
            await waitUntil { fixture.transport.registrations.count == 2 }
            fixture.transport.respond(to: 1, receiver: 101)
            await registration.value
            await repeated.value
            XCTAssertEqual(fixture.transport.registrationTokens, ["01", "01"])
            XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 101)
        }
    }

    func testTokenChangedDuringBackoffSkipsTheSupersededToken() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let first = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        fixture.transport.respond(to: 0, error: (429, "Too Many Requests: retry after 2640"))
        await waitUntil { fixture.clock.waitingCount == 1 }
        let latest = Task { await fixture.service.updatePushDeviceToken(Data([2])) }
        await waitUntil { fixture.service.push.state.withLock { $0.pendingToken == "02" } }
        fixture.clock.advance(seconds: 2640)
        await waitUntil { fixture.transport.registrations.count == 2 }
        XCTAssertEqual(fixture.transport.registrationTokens, ["01", "02"])
        fixture.transport.respond(to: 1, receiver: 202)
        await first.value
        await latest.value
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 202)
    }

    func testLifecycleInvalidationCancelsBackoffAndAllowsReplacementRegistration() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let first = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        fixture.transport.respond(to: 0, error: (429, "Too Many Requests: retry after 2640"))
        await waitUntil { fixture.clock.waitingCount == 1 }
        fixture.service.push.invalidate(clearRegistered: true)
        await first.value
        XCTAssertEqual(fixture.clock.waitingCount, 0)
        // Simulate the lifecycle installing a new ready client. The same account
        // keeps its registration deadline even though the old worker was canceled.
        fixture.service.push.state.withLock { $0.isReady = true }
        let replacement = Task { await fixture.service.push.registerPendingIfNeeded() }
        await waitUntil { fixture.clock.waitingCount == 1 }
        XCTAssertEqual(fixture.transport.registrations.count, 1)
        fixture.clock.advance(seconds: 2640)
        await waitUntil { fixture.transport.registrations.count == 2 }
        fixture.transport.respond(to: 1, receiver: 101)
        await replacement.value
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 101)
    }

    func testLateSuccessAfterClientReplacementCannotRestoreOldRegistration() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let old = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        fixture.service.push.invalidate(clearRegistered: true)
        let replacementTransport = PushTestTransport(clientId: 124)
        let replacementClient = replacementTransport.wrapper()
        defer { replacementClient.stop() }
        replacementClient.startReceiveLoop { _ in }
        fixture.service.session.replaceClientForTesting(replacementClient)
        fixture.service.push.state.withLock { $0.isReady = true }
        let replacement = Task { await fixture.service.updatePushDeviceToken(Data([2])) }
        await waitUntil { replacementTransport.registrations.count == 1 }
        fixture.transport.respond(to: 0, receiver: 101)
        replacementTransport.respond(to: 0, receiver: 202)
        await old.value
        await replacement.value
        XCTAssertEqual(fixture.service.push.state.withLock { $0.registeredToken }, "02")
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 202)
    }

    func testCancellingOneCallerDoesNotCancelSharedRegistration() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        let first = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        await waitUntil { fixture.transport.registrations.count == 1 }
        let second = Task { await fixture.service.updatePushDeviceToken(Data([1])) }
        first.cancel()
        fixture.transport.respond(to: 0, receiver: 101)
        await first.value
        await second.value
        XCTAssertEqual(fixture.transport.registrations.count, 1)
        XCTAssertEqual(fixture.service.push.state.withLock { $0.receiverId }, 101)
    }

    func testTokenWaitsForReadyAndMalformedResponseCannotMarkSuccess() async throws {
        let fixture = try PushFixture()
        defer { fixture.cleanup() }
        fixture.service.push.state.withLock { $0.isReady = false }
        await fixture.service.updatePushDeviceToken(Data([1]))
        XCTAssertTrue(fixture.transport.registrations.isEmpty)
        fixture.service.push.state.withLock { $0.isReady = true }
        let registration = Task { await fixture.service.push.registerPendingIfNeeded() }
        await waitUntil { fixture.transport.registrations.count == 1 }
        fixture.transport.respond(to: 0, receiver: 0)
        await registration.value
        XCTAssertNil(fixture.service.push.state.withLock { $0.registeredToken })
        XCTAssertNil(fixture.service.push.state.withLock { $0.receiverId })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "Expected offline transport state was not reached", file: file, line: line)
    }
}

private struct PushFixture {
    let directory: URL
    let service: TDLibService
    let transport: PushTestTransport
    let client: TDJsonWrapper
    let clock: PushTestClock
    init() throws {
        let clock = PushTestClock()
        self.clock = clock
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("push-registration-\(UUID().uuidString)")
        let throttle = TDRequestThrottle(minSpacing: .zero, now: { [clock] in clock.now },
                                         sleep: { [clock] in try await clock.sleep(for: $0) })
        service = TDLibService(databaseDirectory: directory, requestThrottle: throttle,
                               removeDatabaseKey: { XCTFail("Registration must never remove the database key") })
        transport = PushTestTransport(clientId: 123)
        client = transport.wrapper()
        service.session.replaceClientForTesting(client)
        service.push.state.withLock { $0.isReady = true }
        client.startReceiveLoop { _ in }
    }
    func cleanup() {
        service.push.invalidate()
        client.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Manually advanced monotonic clock; long server delays take no wall time.
private final class PushTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var waitingCount: Int { lock.withLock { waiters.count } }
    func advance(seconds: Int) {
        let ready = lock.withLock {
            instant += .seconds(seconds)
            let ready = waiters.filter { $0.value.0 <= instant }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return ready.values.map(\.1)
        }
        ready.forEach { $0.resume() }
    }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    waiters[id] = (instant + duration, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// Injected JSON boundary only; never initializes native TDLib or contacts Telegram.
private final class PushTestTransport: @unchecked Sendable {
    let clientId: Int32
    private let condition = NSCondition()
    private var requests: [[String: Any]] = []
    private var responses: [String] = []
    private var closing = false
    init(clientId: Int32) { self.clientId = clientId }
    var registrations: [[String: Any]] { condition.withLock { requests } }
    var registrationTokens: [String] {
        registrations.map { ($0["device_token"] as? [String: Any])?["device_token"] as? String ?? "" }
    }
    func wrapper() -> TDJsonWrapper {
        TDJsonWrapper(clientId: clientId, send: { [self] _, json in send(json) },
                      receive: { [self] in receive(timeout: $0) })
    }
    private func send(_ json: String) {
        let request = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if request["@type"] as? String == "close" {
            condition.withLock { closing = true }
            enqueue(["@type": "updateAuthorizationState", "authorization_state": ["@type": "authorizationStateClosed"]])
        } else if request["@type"] as? String == "registerDevice" {
            condition.withLock { requests.append(request) }
        } else {
            enqueue(["@type": "ok", "@extra": request["@extra"]!])
        }
    }
    func respond(to index: Int, receiver: Int64) {
        let extra = registrations[index]["@extra"]!
        enqueue(["@type": "pushReceiverId", "id": receiver, "@extra": extra])
    }
    func respond(to index: Int, error: (Int, String)) {
        let extra = registrations[index]["@extra"]!
        enqueue(["@type": "error", "code": error.0, "message": error.1, "@extra": extra])
    }
    private func enqueue(_ response: [String: Any]) {
        var response = response
        response["@client_id"] = clientId
        let data = try! JSONSerialization.data(withJSONObject: response)
        condition.withLock {
            responses.append(String(decoding: data, as: UTF8.self))
            condition.broadcast()
        }
    }
    private func receive(timeout: Double) -> String? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses.isEmpty {
            if closing || timeout == 0 || !condition.wait(until: deadline) { return nil }
        }
        return responses.removeFirst()
    }
}
