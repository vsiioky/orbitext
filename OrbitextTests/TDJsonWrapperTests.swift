import XCTest
@testable import OrbitextWatch

final class TDJsonWrapperTests: XCTestCase {
    func testStopResolvesPendingRequests() async throws {
        let wrapper = TDJsonWrapper()

        // Do not start the receive loop so the request stays pending until stop().
        let expectation = XCTestExpectation(description: "Pending request should fail as abandoned")

        Task {
            do {
                _ = try await wrapper.send(["@type": "getOption", "name": "version"])
                XCTFail("Expected error")
            } catch let error as TDError {
                switch error {
                // It reached TDLib, so callers must not treat it as never sent.
                case .requestAbandoned, .timeout:
                    break // Expected
                default:
                    XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }

        // Give the send a moment to register
        try await Task.sleep(nanoseconds: 100_000_000)

        wrapper.stop()

        await fulfillment(of: [expectation], timeout: 5)
        try await wrapper.stopAndWait()
    }

    func testStopAndWaitResolvesPendingRequests() async throws {
        let wrapper = TDJsonWrapper()

        let expectation = XCTestExpectation(description: "Pending request should fail before stopAndWait returns")

        Task {
            do {
                _ = try await wrapper.send(["@type": "getOption", "name": "version"])
                XCTFail("Expected error")
            } catch let error as TDError {
                switch error {
                // It reached TDLib, so callers must not treat it as never sent.
                case .requestAbandoned, .timeout:
                    break
                default:
                    XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        try await wrapper.stopAndWait()

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testCancelledSendRemovesPendingRequest() async throws {
        let wrapper = TDJsonWrapper()

        let task = Task {
            _ = try await wrapper.sendWithoutTimeout(["@type": "getOption", "name": "version"])
        }

        while wrapper.pendingRequestCountForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(wrapper.pendingRequestCountForTesting, 0)
        try await wrapper.stopAndWait()
    }

    /// An idle client must wait inside td_receive, which blocks until TDLib has
    /// something to say. Polling with a zero timeout and a sleep wakes the CPU
    /// every few milliseconds for nothing on a battery-powered watch.
    func testIdleReceiveLoopParksInOneBlockingReceive() async throws {
        let transport = ScriptedTDTransport()
        let wrapper = transport.wrapper()
        let updates = UpdateCounter()
        wrapper.startReceiveLoop { _ in updates.increment() }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.receiveTimeouts, [1.0], "An idle loop has to block in td_receive, not poll")

        transport.emit(["@type": "updateOption", "name": "probe",
                        "value": ["@type": "optionValueBoolean", "value": true]])
        let deadline = ContinuousClock.now + .seconds(2)
        while updates.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(updates.value, 1)
        // The wake-up is followed by one non-blocking drain of anything else
        // already queued, and then by blocking again.
        XCTAssertEqual(transport.receiveTimeouts, [1.0, 0, 1.0])
        try await wrapper.stopAndWait()
    }

    /// td_receive may not run on two threads at once, and its result sits in a
    /// buffer the next call reuses, so it is copied before the lock is released.
    func testSerializedReceiveHandsItsTimeoutToTheNativeCall() {
        let seen = NSLock()
        var timeouts: [Double] = []

        _ = TDJsonWrapper.serializedReceive(timeout: 0.75) { timeout in
            seen.withLock { timeouts.append(timeout) }
            return nil
        }

        // A 0 here would turn the idle receive loop into a busy spin.
        XCTAssertEqual(seen.withLock { timeouts }, [0.75])
    }

    func testConcurrentReceivesAreSerializedAndCopiedBeforeTheLockIsReleased() {
        let payloadLength = 64 * 1024
        let sharedBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: payloadLength + 1)
        defer { sharedBuffer.deallocate() }
        nonisolated(unsafe) let buffer = sharedBuffer
        let probe = ReceiveProbe()
        let workers = 4
        let rounds = 150

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let fill = CChar(65 + worker)
            for _ in 0..<rounds {
                let received = TDJsonWrapper.serializedReceive(timeout: 0) { _ in
                    probe.enter()
                    defer { probe.leave() }
                    // Every call writes into the one buffer, as td_receive does.
                    memset(buffer, Int32(fill), payloadLength)
                    buffer[payloadLength] = 0
                    usleep(20)
                    return UnsafePointer(buffer)
                }
                probe.check(received, isFilledWith: UInt8(fill), length: payloadLength)
            }
        }

        XCTAssertEqual(probe.maximumConcurrentReceives, 1, "td_receive ran on several threads at once")
        XCTAssertEqual(probe.corruptedResults, 0, "A result was overwritten by another receive before it was copied")
        XCTAssertEqual(probe.completedResults, workers * rounds)
    }

    func testTimeoutError() {
        // Verify TDError.timeout has correct description
        let error = TDError.timeout
        XCTAssertEqual(error.errorDescription, "Request timed out")
        XCTAssertFalse(error.isFloodWait)
        XCTAssertFalse(error.isSessionRevoked)
        XCTAssertNil(error.floodWaitSeconds)
    }

    func testFloodWaitDetection() {
        let error = TDError.api(code: 420, message: "FLOOD_WAIT_30")
        XCTAssertTrue(error.isFloodWait)
        XCTAssertEqual(error.floodWaitSeconds, 30)
    }

    func testNativeRetryAfterIsRecognizedAsTransientRateLimit() {
        for error in [TDError.api(code: 429, message: "Too Many Requests: retry after 2640"),
                      .api(code: 420, message: "FLOOD_WAIT_2640")] {
            XCTAssertEqual(error.floodWaitSeconds, 2640)
            XCTAssertTrue(error.isFloodWait)
            XCTAssertEqual(error.category, .transient)
        }
    }

    func testMalformedRetryAfterDoesNotCreateABackoff() {
        for error in [TDError.api(code: 400, message: "Too Many Requests: retry after 2640"),
                      .api(code: 429, message: "Too Many Requests: retry after -1"),
                      .api(code: 429, message: "Too Many Requests: retry after 0"),
                      .api(code: 429, message: "Too Many Requests: retry after 20 trailing"),
                      .api(code: 420, message: "FLOOD_WAIT_"),
                      .api(code: 420, message: "FLOOD_WAIT_-1")] {
            XCTAssertNil(error.floodWaitSeconds)
            XCTAssertFalse(error.isFloodWait)
        }
    }

    func testSessionRevokedDetection() {
        let error1 = TDError.api(code: 401, message: "SESSION_REVOKED")
        XCTAssertTrue(error1.isSessionRevoked)

        let error2 = TDError.api(code: 401, message: "AUTH_KEY_UNREGISTERED")
        XCTAssertTrue(error2.isSessionRevoked)

        let error3 = TDError.api(code: 400, message: "PHONE_NUMBER_INVALID")
        XCTAssertFalse(error3.isSessionRevoked)
    }
}

private final class UpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Records how a fake td_receive was entered and what its callers got back.
private final class ReceiveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var peak = 0
    private var corrupted = 0
    private var completed = 0
    var maximumConcurrentReceives: Int { lock.withLock { peak } }
    var corruptedResults: Int { lock.withLock { corrupted } }
    var completedResults: Int { lock.withLock { completed } }

    func enter() {
        lock.withLock {
            inside += 1
            peak = max(peak, inside)
        }
    }

    func leave() {
        lock.withLock { inside -= 1 }
    }

    func check(_ result: String?, isFilledWith byte: UInt8, length: Int) {
        let intact = result.map { $0.utf8.count == length && $0.utf8.allSatisfy { $0 == byte } } ?? false
        lock.withLock {
            completed += 1
            if !intact { corrupted += 1 }
        }
    }
}
