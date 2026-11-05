import XCTest
@testable import OrbitextWatch

final class TDLibServiceLifecycleTests: XCTestCase {
    func testCurrentTDClientCheckRejectsReplacedClient() async throws {
        let service = TDLibService()
        let oldClient = TDJsonWrapper()
        let currentClient = TDJsonWrapper()

        service.session.replaceClientForTesting(oldClient)
        XCTAssertTrue(service.isCurrentTDClient(oldClient))

        service.session.replaceClientForTesting(currentClient)

        XCTAssertFalse(service.isCurrentTDClient(oldClient))
        XCTAssertTrue(service.isCurrentTDClient(currentClient))
        try await oldClient.stopAndWait()
        try await currentClient.stopAndWait()
    }

    /// An `ok` response to close must not count as completed teardown. Require
    /// the final native Closed update that releases ClientManager's client.
    func testStopAndWaitDrainsReceiveTask() async throws {
        let client = TDJsonWrapper()
        client.startReceiveLoop { _ in }
        await Task.yield()

        try await client.stopAndWait()
        XCTAssertTrue(client.isNativeClosed)

        // After stopAndWait returns, the wrapper is closed and must reject
        // new sends immediately instead of registering continuations that
        // can only time out because the receive loop is gone.
        do {
            _ = try await client.send(["@type": "getMe"], timeoutNanos: 100_000_000)
            XCTFail("send() should not succeed after stopAndWait()")
        } catch TDError.clientClosed {
            // ok
        } catch {
            XCTFail("Unexpected error after stopAndWait(): \(error)")
        }
    }

    func testStopWithoutReceiveLoopCanBeFullyDrainedLater() async throws {
        let client = TDJsonWrapper()
        client.stop()

        try await client.stopAndWait()
        XCTAssertTrue(client.isNativeClosed)

        client.stop()
        try await client.stopAndWait(timeout: .zero)
    }

    func testConcurrentNativeClientShutdownObservesEachFinalClosedUpdate() async throws {
        let first = TDJsonWrapper()
        let second = TDJsonWrapper()
        async let firstClosed = first.stopAndWait()
        async let secondClosed = second.stopAndWait()
        _ = try await (firstClosed, secondClosed)
        XCTAssertTrue(first.isNativeClosed)
        XCTAssertTrue(second.isNativeClosed)
    }

    func testConcurrentShutdownOfSameClientAwaitsCompletedNativeClose() async throws {
        let client = TDJsonWrapper()
        client.startReceiveLoop { _ in }
        async let firstClosed = client.stopAndWait()
        async let secondClosed = client.stopAndWait()
        _ = try await (firstClosed, secondClosed)
        XCTAssertTrue(client.isNativeClosed)
    }

    func testNativeCloseRemainsRetryableAfterZeroTimeout() async throws {
        let client = TDJsonWrapper()
        do {
            try await client.stopAndWait(timeout: .zero)
        } catch TDError.timeout {}
        // The first wait may already see Closed on a fast scheduler. In either
        // outcome the wrapper must remain drainable rather than strand TDLib.
        try await client.stopAndWait()
        XCTAssertTrue(client.isNativeClosed)
    }

    func testDatabaseKeyResolveUsesExistingKey() throws {
        let existing = Data(repeating: 7, count: 32)

        let resolved = try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/tmp/db"),
            loadKey: { existing },
            storeKey: { _ in XCTFail("Existing keys must not be overwritten") },
            generateKey: {
                XCTFail("Existing keys must not trigger generation")
                return Data()
            },
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolved.key, existing)
        XCTAssertFalse(resolved.needsMigration)
    }

    func testDatabaseKeyResolveAllowsExplicitLegacyMigration() throws {
        let resolved = try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/tmp/db"),
            loadKey: { nil },
            storeKey: { _ in XCTFail("Legacy DB must be opened with empty key before migration") },
            generateKey: {
                XCTFail("Legacy DB must not generate a new key before TDLib opens it")
                return Data()
            },
            fileExists: { path in path.hasSuffix("td.binlog") }
        )

        XCTAssertTrue(resolved.key.isEmpty)
        XCTAssertTrue(resolved.needsMigration)
    }

    func testDatabaseKeyResolveGeneratesAndStoresFreshInstallKey() throws {
        let fresh = Data(repeating: 9, count: 32)
        var storedKey: Data?

        let resolved = try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/tmp/db"),
            loadKey: { nil },
            storeKey: { storedKey = $0 },
            generateKey: { fresh },
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolved.key, fresh)
        XCTAssertEqual(storedKey, fresh)
        XCTAssertFalse(resolved.needsMigration)
    }

    func testDatabaseKeyResolveFailsClosedWhenKeychainLoadFails() {
        XCTAssertThrowsError(try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/tmp/db"),
            loadKey: { throw TestError.failed("keychain unavailable") },
            storeKey: { _ in },
            generateKey: { Data(repeating: 1, count: 32) },
            fileExists: { _ in false }
        ))
    }

    func testDatabaseKeyResolveFailsClosedWhenFreshKeyCannotBeStored() {
        XCTAssertThrowsError(try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/tmp/db"),
            loadKey: { nil },
            storeKey: { _ in throw TestError.failed("store denied") },
            generateKey: { Data(repeating: 1, count: 32) },
            fileExists: { _ in false }
        ))
    }

    /// A caller that cancels while the service waits for TDLib to reach the
    /// right auth state must get CancellationError at once. Swallowing the
    /// cancellation turns the wait into a busy loop until its timeout.
    func testCancelledAuthWaitEndsWithCancellationInsteadOfSpinningToTheTimeout() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        // A client that has not reported waitPhoneNumber yet: the call polls for it.
        let start = ContinuousClock.now
        let call = Task { try await fixture.service.setPhoneNumber("+15550100123") }
        try await Task.sleep(for: .milliseconds(150))
        call.cancel()

        do {
            try await call.value
            XCTFail("setPhoneNumber cannot succeed before the auth state arrives")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "The cancelled wait kept polling")
        XCTAssertTrue(fixture.transport.requests.isEmpty, "Nothing may be sent for a cancelled call")
    }
}
