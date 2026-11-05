import Synchronization
import XCTest
@testable import OrbitextWatch

/// `start()` on scripted clients: the receive loop, the update queue, the
/// auth queue and the bootstrap answer that production runs, with the events
/// they emit and the generation markers around them. Run under Thread
/// Sanitizer (`scripts/verify.sh --tsan`), this is the only test of the
/// path that updates and the bootstrap answer take into the coordinator
/// while a transition closes the client they came from.
final class TDServiceStartTests: XCTestCase {
    private static func updateAuthorizationState(_ type: String) -> [String: Any] {
        ["@type": "updateAuthorizationState", "authorization_state": ["@type": type]]
    }

    func testStatesFromTheReceiveLoopAreReportedInOrderBeforeTheMarkerThatRetiresTheirClient() async throws {
        let fixture = StartedServiceFixture { request in
            if request["@type"] as? String == "getAuthorizationState" {
                return .result(["@type": "authorizationStateWaitPhoneNumber"])
            }
            return .result(["@type": "ok"])
        }
        defer { fixture.finish() }
        let service = fixture.service
        let events = Task { [events = service.events] () -> [String] in
            var labels: [String] = []
            for await event in events { labels.append(Self.label(event)) }
            return labels
        }

        await service.start()
        try await waitUntil { service.auth.observedState == .waitPhoneNumber }

        // A burst the receive loop still works through when the close starts,
        // each state taking a while: the close waits for the whole burst, and
        // the marker comes after all of it.
        service.auth.setAfterClientCheckForTesting { Thread.sleep(forTimeInterval: 0.005) }
        let burst = (0..<40).map { $0.isMultiple(of: 2) ? "authorizationStateWaitCode" : "authorizationStateWaitPhoneNumber" }
        for type in burst {
            fixture.transports[0].emit(Self.updateAuthorizationState(type))
        }
        try await service.completeLocalLogoutCleanup()
        service.session.finishEventsForTesting()
        let labels = await events.value

        let states = burst.map { $0 == "authorizationStateWaitCode" ? "auth waitCode" : "auth waitPhoneNumber" }
        XCTAssertEqual(labels, ["generation 1", "chatListSessionStarted", "auth waitPhoneNumber"]
            + states + ["generation 2", "auth waitPhoneNumber"],
            "A state of the old client followed the marker that retired it, or states were reordered")
    }

    func testEachClientOfARestartGetsItsOwnParameters() async throws {
        let fixture = StartedServiceFixture { request in
            if request["@type"] as? String == "getAuthorizationState" {
                return .result(["@type": "authorizationStateWaitTdlibParameters"])
            }
            return .result(["@type": "ok"])
        }
        defer { fixture.finish() }

        await fixture.service.start()
        try await waitUntil { fixture.transports[0].methods.contains("setTdlibParameters") }
        await fixture.service.start()
        try await waitUntil { fixture.transports.count == 2 && fixture.transports[1].methods.contains("setTdlibParameters") }

        XCTAssertEqual(fixture.transports[0].requests(ofType: "setTdlibParameters").count, 1)
        XCTAssertEqual(fixture.transports[1].requests(ofType: "setTdlibParameters").count, 1,
                       "The restarted client never got its parameters")
        XCTAssertTrue(fixture.service.session.generation.rawValue >= 3, "The restart did not retire the first client")
    }

    // MARK: - Helpers

    private static func label(_ event: TDLibEvent) -> String {
        switch event {
        case .clientGenerationChanged(let generation): return "generation \(generation.rawValue)"
        case .chatListSessionStarted: return "chatListSessionStarted"
        case .authStateChanged(let state): return "auth \(state)"
        default: return "other"
        }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the transport") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A real `TDLibService` whose every `start()` runs a scripted client, one
/// transport per start.
private final class StartedServiceFixture: Sendable {
    let service: TDLibService
    private let directory: URL
    private let log: ClientLog

    init(script: @escaping ScriptedTDTransport.Script) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("started-service-\(UUID().uuidString)", isDirectory: true)
        let log = ClientLog(script: script)
        self.log = log
        service = TDLibService(
            databaseDirectory: directory,
            nativeCloseTimeout: .seconds(5),
            requestThrottle: TDRequestThrottle(minSpacing: .zero),
            apiCredentials: (id: 1, hash: "hash"),
            resolveDatabaseKey: { _ in (Data([1, 2, 3]), false) },
            removeDatabaseKey: {},
            makeClient: { log.makeClient() }
        )
    }

    /// The transport of each start so far, in order.
    var transports: [ScriptedTDTransport] { log.transports }

    func finish() {
        service.session.replaceClientForTesting(nil)
        log.stopAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ClientLog: @unchecked Sendable {
    private let lock = NSLock()
    private let script: ScriptedTDTransport.Script
    private var entries: [(transport: ScriptedTDTransport, client: TDJsonWrapper)] = []

    init(script: @escaping ScriptedTDTransport.Script) {
        self.script = script
    }

    func makeClient() -> TDJsonWrapper {
        lock.withLock {
            let transport = ScriptedTDTransport(clientId: Int32(9200 + entries.count), script: script)
            let client = transport.wrapper()
            entries.append((transport, client))
            return client
        }
    }

    var transports: [ScriptedTDTransport] { lock.withLock { entries.map(\.transport) } }

    func stopAll() {
        for client in lock.withLock({ entries.map(\.client) }) { client.stop() }
    }
}
