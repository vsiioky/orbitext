import Synchronization
import XCTest
@testable import OrbitextWatch

/// The account's online status on the real transport: what goes to TDLib
/// when the app moves between foreground and background, and when the
/// receive loop pauses, observed through a scripted client.
final class PresenceTransportTests: XCTestCase {
    func testBackgroundSendsOfflineAndPausesTheReceiveLoopOnceApplied() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        fixture.service.suspendForBackground()

        try await waitUntil { fixture.client.isPaused }
        XCTAssertEqual(onlineValues(of: fixture), [false])
    }

    func testBackgroundAgainOnlyPausesWithoutSendingTheSameStatus() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        fixture.service.suspendForBackground()
        try await waitUntil { fixture.client.isPaused }
        fixture.client.resume()

        fixture.service.suspendForBackground()

        XCTAssertTrue(fixture.client.isPaused, "An applied offline status pauses at once")
        XCTAssertEqual(onlineValues(of: fixture), [false])
    }

    func testForegroundResumesTheReceiveLoopAndSendsOnline() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        fixture.service.suspendForBackground()
        try await waitUntil { fixture.client.isPaused }

        fixture.service.resumeFromBackground()

        XCTAssertFalse(fixture.client.isPaused, "The receive loop must run before online goes out")
        try await waitUntil { onlineValues(of: fixture) == [false, true] }
        XCTAssertFalse(fixture.client.isPaused)
    }

    func testOnlineAppliedOnceIsNotSentAgain() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        fixture.service.resumeFromBackground()
        try await waitUntil { onlineValues(of: fixture) == [true] }
        // Let the answer land before the next change.
        try await Task.sleep(for: .milliseconds(50))

        fixture.service.resumeFromBackground()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(onlineValues(of: fixture), [true])
    }

    func testForegroundWhileOfflineIsStillPendingEndsOnlineAndRunning() async throws {
        let fixture = ScriptedServiceFixture { request in
            if request["name"] as? String == "online", Self.onlineValue(of: request) == false {
                return .delayed(0.2, ["@type": "ok"])
            }
            return .result(["@type": "ok"])
        }
        defer { fixture.finish() }
        fixture.service.suspendForBackground()
        try await waitUntil { onlineValues(of: fixture) == [false] }

        fixture.service.resumeFromBackground()

        try await waitUntil { onlineValues(of: fixture) == [false, true] }
        // The offline answer arrives later and must not pause the loop.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(fixture.client.isPaused, "A late offline answer paused the foreground app")
        XCTAssertEqual(onlineValues(of: fixture), [false, true])
    }

    /// The offline answer decides to pause the loop and the app comes to the
    /// foreground before the pause lands: the pause may not follow the
    /// resume, or the online status sent next is never answered.
    func testForegroundBetweenTheOfflineAnswerAndThePauseLeavesTheLoopRunning() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let atPause = Mutex(false)
        let letPauseGo = DispatchSemaphore(value: 0)
        fixture.service.presence.setBeforePauseForTesting {
            atPause.withLock { $0 = true }
            _ = letPauseGo.wait(timeout: .now() + 5)
        }
        fixture.service.suspendForBackground()
        try await waitUntil { atPause.withLock { $0 } }

        // The pause is about to be applied. Foreground comes from its own
        // thread: it may have to wait for the pause in progress.
        let foregroundDone = Mutex(false)
        DispatchQueue.global().async {
            fixture.service.resumeFromBackground()
            foregroundDone.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        letPauseGo.signal()

        try await waitUntil { foregroundDone.withLock { $0 } }
        try await waitUntil { onlineValues(of: fixture) == [false, true] }
        // Time for a late pause to land.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(fixture.client.isPaused, "A paused loop never reads the answer to the online status")
    }

    /// A status TDLib refused (a flood wait, say) is not applied: asking for
    /// the same status again has to send it again.
    func testOnlineRefusedByTDLibIsSentAgainWhenAskedAgain() async throws {
        let fixture = Self.fixtureRefusingTheFirstOnlineStatus()
        defer { fixture.finish() }
        fixture.service.resumeFromBackground()
        try await waitUntil { onlineValues(of: fixture) == [true] }
        // Let the refusal land before the next ask.
        try await Task.sleep(for: .milliseconds(100))

        fixture.service.resumeFromBackground()

        try await waitUntil { onlineValues(of: fixture) == [true, true] }
    }

    /// A refused offline status leaves the receive loop running: TDLib has
    /// not taken the status, and the loop pauses only once it has.
    func testOfflineRefusedByTDLibKeepsTheLoopRunningAndIsSentAgain() async throws {
        let fixture = Self.fixtureRefusingTheFirstOnlineStatus()
        defer { fixture.finish() }
        fixture.service.suspendForBackground()
        try await waitUntil { onlineValues(of: fixture) == [false] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.client.isPaused, "A refused offline status paused the loop")

        fixture.service.suspendForBackground()

        try await waitUntil { onlineValues(of: fixture) == [false, false] }
        try await waitUntil { fixture.client.isPaused }
    }

    /// Nobody asks a second time: the refused offline status has to come
    /// back by itself after the wait, or the account stays online and the
    /// receive loop runs for the whole stay in the background.
    func testOfflineRefusedByTDLibIsSentAgainAfterTheWaitAndPausesTheLoop() async throws {
        let fixture = Self.fixtureRefusingTheFirstOnlineStatus()
        defer { fixture.finish() }

        fixture.service.suspendForBackground()

        try await waitUntil(timeout: .seconds(5)) { onlineValues(of: fixture) == [false, false] }
        try await waitUntil { fixture.client.isPaused }
    }

    func testOnlineRefusedByTDLibIsSentAgainAfterTheWait() async throws {
        let fixture = Self.fixtureRefusingTheFirstOnlineStatus()
        defer { fixture.finish() }

        fixture.service.resumeFromBackground()

        try await waitUntil(timeout: .seconds(5)) { onlineValues(of: fixture) == [true, true] }
        XCTAssertFalse(fixture.client.isPaused)
    }

    /// The refused offline status is stale once the app is back in front:
    /// the wait ends with nothing left to send.
    func testRefusedOfflineIsNotSentAgainAfterTheAppCameBack() async throws {
        let fixture = Self.fixtureRefusingTheFirstOnlineStatus()
        defer { fixture.finish() }
        fixture.service.suspendForBackground()
        try await waitUntil { onlineValues(of: fixture) == [false] }
        try await Task.sleep(for: .milliseconds(100))

        fixture.service.resumeFromBackground()

        try await waitUntil { onlineValues(of: fixture) == [false, true] }
        // Past the one second wait of the refusal.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(onlineValues(of: fixture), [false, true])
        XCTAssertFalse(fixture.client.isPaused)
    }

    // MARK: - Helpers

    /// TDLib answers the first online status with a flood wait and takes the
    /// ones after it.
    private static func fixtureRefusingTheFirstOnlineStatus() -> ScriptedServiceFixture {
        let refusals = Mutex(1)
        return ScriptedServiceFixture { request in
            guard request["name"] as? String == "online" else { return .result(["@type": "ok"]) }
            let refuse = refusals.withLock { count -> Bool in
                defer { count = max(0, count - 1) }
                return count > 0
            }
            return refuse ? .error(code: 429, message: "Too Many Requests: retry after 1") : .result(["@type": "ok"])
        }
    }

    private func onlineValues(of fixture: ScriptedServiceFixture) -> [Bool] {
        fixture.transport.requests(ofType: "setOption")
            .filter { $0["name"] as? String == "online" }
            .compactMap(Self.onlineValue(of:))
    }

    private static func onlineValue(of request: [String: Any]) -> Bool? {
        (request["value"] as? [String: Any])?["value"] as? Bool
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the transport") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
