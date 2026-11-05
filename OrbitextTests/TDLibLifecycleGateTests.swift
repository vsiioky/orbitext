import XCTest
@testable import OrbitextWatch

@MainActor
final class TDLibLifecycleGateTests: XCTestCase {
    func testDatabaseOperationWaitsWhilePreviousClientIsClosing() async throws {
        let gate = TDClientLifecycleGate()
        let closing = try await gate.acquire()
        var order = ["client detached"]
        let cleanup = Task {
            let lease = try await gate.acquire()
            defer { lease.release() }
            order.append("database removed")
        }

        await waitForWaiter(on: gate)
        XCTAssertEqual(order, ["client detached"], "No database access while close is suspended")
        order.append("native close confirmed")
        closing.release()
        try await cleanup.value
        XCTAssertEqual(order, ["client detached", "native close confirmed", "database removed"])
    }

    func testCanceledWaiterCannotRetainOrStealOwnership() async throws {
        let gate = TDClientLifecycleGate()
        let first = try await gate.acquire()
        let canceledWaiter = Task {
            let lease = try await gate.acquire()
            lease.release()
        }
        await waitForWaiter(on: gate)
        canceledWaiter.cancel()
        do {
            try await canceledWaiter.value
            XCTFail("Canceled waiter must throw")
        } catch is CancellationError {}
        XCTAssertEqual(gate.waitingCountForTesting, 0)

        var successorEntered = false
        let successor = Task {
            let lease = try await gate.acquire()
            defer { lease.release() }
            successorEntered = true
        }
        await waitForWaiter(on: gate)
        XCTAssertFalse(successorEntered, "Canceling a waiter must not release the current owner's lease")
        first.release()
        try await successor.value
        XCTAssertTrue(successorEntered)
    }

    func testCancellationBeforeAcquireLeavesGateAvailable() async throws {
        let gate = TDClientLifecycleGate()
        let canceled = Task {
            let lease = try await gate.acquire()
            lease.release()
        }
        canceled.cancel()
        do {
            try await canceled.value
            XCTFail("Already canceled task must not acquire")
        } catch is CancellationError {}

        let lease = try await gate.acquire()
        lease.release()
    }

    func testRepeatedLeaseReleaseCannotReleaseTheNextOwner() async throws {
        let gate = TDClientLifecycleGate()
        let first = try await gate.acquire()
        first.release()
        let second = try await gate.acquire()
        first.release()

        var thirdEntered = false
        let third = Task {
            let lease = try await gate.acquire()
            defer { lease.release() }
            thirdEntered = true
        }
        await waitForWaiter(on: gate)
        XCTAssertFalse(thirdEntered)
        second.release()
        try await third.value
        XCTAssertTrue(thirdEntered)
    }

    func testQueuedClosedRecoveryCannotRemoveReplacementClientState() async throws {
        try await assertQueuedRecoveryPreservesReplacement(forceLogout: false)
    }

    func testQueuedForcedLogoutCannotRemoveReplacementClientState() async throws {
        try await assertQueuedRecoveryPreservesReplacement(forceLogout: true)
    }

    private func assertQueuedRecoveryPreservesReplacement(forceLogout: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TDLibService(databaseDirectory: directory, removeDatabaseKey: {
            XCTFail("Stale recovery must not remove the replacement database key")
        })
        let replacing = try await service.session.lifecycleGate.acquire()
        let oldClient = TDJsonWrapper(clientId: 1001, send: { _, _ in }, receive: { _ in nil })
        let replacement = TDJsonWrapper(clientId: 1002, send: { _, _ in }, receive: { _ in nil })
        service.session.replaceClientForTesting(oldClient)
        let recovery = Task {
            try await service.recoverClosedClient(oldClient, reason: "stale callback test", forceLogout: forceLogout)
        }
        await waitForWaiter(on: service.session.lifecycleGate)

        service.session.replaceClientForTesting(replacement)
        let replacementKey = Data(repeating: 7, count: 32)
        service.auth.stagedDatabaseKey = replacementKey
        replacing.release()
        try await recovery.value

        XCTAssertTrue(service.isCurrentTDClient(replacement))
        XCTAssertEqual(service.auth.stagedDatabaseKey, replacementKey)
        XCTAssertFalse(replacement.isNativeClosed)
    }

    private func waitForWaiter(on gate: TDClientLifecycleGate, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while gate.waitingCountForTesting == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(gate.waitingCountForTesting, 0, "Lifecycle operation did not queue", file: file, line: line)
    }
}
