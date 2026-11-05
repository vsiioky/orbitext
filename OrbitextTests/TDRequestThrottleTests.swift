import XCTest
@testable import OrbitextWatch

final class TDRequestThrottleTests: XCTestCase {
    func testAcquireSlotSpacesRequests() async {
        let throttle = TDRequestThrottle(minSpacing: .milliseconds(50))

        let start = ContinuousClock.now
        try? await throttle.acquireSlot()
        try? await throttle.acquireSlot()
        let elapsed = ContinuousClock.now - start

        // Second slot should be delayed by at least minSpacing
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(40), "Second slot should enforce spacing")
    }

    func testResetClearsBackoff() async {
        let throttle = TDRequestThrottle(minSpacing: .milliseconds(10))

        // Report a flood wait
        await throttle.reportFloodWait(seconds: 60)

        // Reset should clear backoff
        await throttle.reset()

        // Acquire should be fast (no 60s backoff)
        let start = ContinuousClock.now
        try? await throttle.acquireSlot()
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(1), "After reset, acquire should not be blocked by old flood backoff")
    }

    func testFullServerDelayIsPreservedAcrossClientSpacingReset() async {
        let now = ContinuousClock.now
        let throttle = TDRequestThrottle(minSpacing: .zero, now: { now })
        await throttle.reportFloodWait(seconds: 2640)
        await throttle.resetSpacing()
        let remaining = await throttle.remainingBackoff()
        XCTAssertEqual(remaining, .seconds(2640))
        await throttle.reportFloodWait(seconds: 60)
        let afterShorterError = await throttle.remainingBackoff()
        XCTAssertEqual(afterShorterError, .seconds(2640), "Another error must not shorten the server pause")
    }

    func testPushRegistrationBackoffDoesNotBlockUnrelatedMethods() async throws {
        let now = ContinuousClock.now
        let throttle = TDRequestThrottle(minSpacing: .zero, now: { now })
        await throttle.reportFloodWait(seconds: 2640, method: "registerDevice")
        let pushRemaining = await throttle.remainingBackoff(method: "registerDevice")
        let chatRemaining = await throttle.remainingBackoff(method: "getChats")
        XCTAssertEqual(pushRemaining, .seconds(2640))
        XCTAssertEqual(chatRemaining, .zero)
        try await throttle.acquireSlot(method: "getChats")
    }

    func testPreviousSessionRateLimitCannotRestoreBackoffAfterLogoutReset() async throws {
        let now = ContinuousClock.now
        let throttle = TDRequestThrottle(minSpacing: .zero, now: { now })
        let oldGeneration = await throttle.sessionGeneration
        await throttle.reset()
        let accepted = await throttle.reportFloodWait(seconds: 2640, method: "registerDevice", generation: oldGeneration)
        XCTAssertFalse(accepted)
        let remaining = await throttle.remainingBackoff(method: "registerDevice")
        XCTAssertEqual(remaining, .zero)
        try await throttle.acquireSlot(method: "registerDevice")
        do {
            try await throttle.acquireSlot(method: "registerDevice", generation: oldGeneration)
            XCTFail("A queued request from the old account must not receive a new send slot")
        } catch is CancellationError {}
    }

    func testConcurrentSlotAcquisition() async {
        let throttle = TDRequestThrottle(minSpacing: .milliseconds(20))
        let slotCount = 5

        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<slotCount {
                group.addTask {
                    try? await throttle.acquireSlot()
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        // 5 slots × 20ms spacing = at least 80ms total (first slot is instant)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(60),
            "Concurrent slots should be serialized with spacing")
    }

    func testAcquireSlotPropagatesCancellationDuringBackoff() async {
        let throttle = TDRequestThrottle(minSpacing: .milliseconds(10))
        // A limit below the bound, so the request waits and can be cancelled.
        await throttle.reportFloodWait(seconds: 20)

        let task = Task {
            try await throttle.acquireSlot()
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Cancelled throttle acquisition should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - FLOOD_WAIT scope and bound

    func testLongServerWaitFailsFastInsteadOfQueueing() async {
        let sleeps = ThrottleSleepRecorder()
        let throttle = TDRequestThrottle(minSpacing: .zero, sleep: { duration in
            sleeps.record(duration)
            throw CancellationError()
        })
        await throttle.reportFloodWait(seconds: 2_640, method: "getChats")

        do {
            try await throttle.acquireSlot(method: "getChats")
            XCTFail("A 44-minute server wait must not grant a slot")
        } catch {
            XCTAssertNotNil((error as? TDError)?.floodWaitSeconds,
                            "The caller should get the server limit, got \(error)")
        }
        XCTAssertTrue(sleeps.durations.allSatisfy { $0 < .seconds(60) },
                      "The request was parked for the whole server wait: \(sleeps.durations)")
    }

    func testFloodWaitOnOneMethodDoesNotDelayOthers() async throws {
        let sleeps = ThrottleSleepRecorder()
        let throttle = TDRequestThrottle(minSpacing: .zero, sleep: { duration in
            sleeps.record(duration)
            try await Task.sleep(for: min(duration, .milliseconds(10)))
        })
        let transport = ThrottleTestTransport(floodWaitFor: "getChats", seconds: 60)
        let wrapper = TDJsonWrapper(clientId: 777, send: { _, json in transport.send(json) },
                                    receive: { transport.receive(timeout: $0) })
        wrapper.startReceiveLoop { _ in }
        let service = TDLibService(requestThrottle: throttle)
        service.session.replaceClientForTesting(wrapper)

        _ = try? await service.throttledSend(["@type": "getChats"])
        let result = try await service.throttledSend(["@type": "getMe"])

        XCTAssertEqual(result["@type"] as? String, "ok")
        XCTAssertTrue(sleeps.durations.allSatisfy { $0 < .seconds(1) },
                      "A getChats limit held back an unrelated request: \(sleeps.durations)")
    }
}

private final class ThrottleSleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Duration] = []
    var durations: [Duration] { lock.withLock { stored } }
    func record(_ duration: Duration) { lock.withLock { stored.append(duration) } }
}

/// Answers every request with ok, except one method that hits FLOOD_WAIT.
private final class ThrottleTestTransport: @unchecked Sendable {
    private let condition = NSCondition()
    private var responses: [String] = []
    private let floodMethod: String
    private let seconds: Int

    init(floodWaitFor method: String, seconds: Int) {
        floodMethod = method
        self.seconds = seconds
    }

    func send(_ json: String) {
        guard let data = json.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let extra = request["@extra"] ?? ""
        let response: [String: Any] = request["@type"] as? String == floodMethod
            ? ["@type": "error", "code": 420, "message": "FLOOD_WAIT_\(seconds)", "@extra": extra, "@client_id": 777]
            : ["@type": "ok", "@extra": extra, "@client_id": 777]
        let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        condition.withLock {
            responses.append(encoded)
            condition.broadcast()
        }
    }

    func receive(timeout: Double) -> String? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses.isEmpty {
            if timeout == 0 || !condition.wait(until: deadline) { return nil }
        }
        return responses.removeFirst()
    }
}
