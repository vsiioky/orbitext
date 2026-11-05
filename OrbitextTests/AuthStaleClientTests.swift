import Dispatch
import Synchronization
import XCTest
@testable import OrbitextWatch

/// A state of a client that is retired while its handler runs. The auth
/// queue orders handlers among themselves, not against the transitions that
/// retire a client and start the next one, so a handler that checked its
/// client at the start must still change nothing of the next client's:
/// not the flag that sends its parameters, not its push registration, not
/// its online status, and report nothing.
final class AuthStaleClientTests: XCTestCase {
    private let qrLinkState: [String: Any] = [
        "@type": "authorizationStateWaitOtherDeviceConfirmation",
        "link": "tg://login?token=retired"
    ]

    func testParametersOfARetiredClientDoNotStopTheNextClientFromGettingItsOwn() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let next = NextClient()
        defer { next.stop() }

        try await handleWhileRetired(["@type": "authorizationStateWaitTdlibParameters"], in: fixture, next: next)
        fixture.service.handleAuthUpdate(["@type": "authorizationStateWaitTdlibParameters"], sourceClient: next.client)

        let sent = await eventually { next.transport.methods.contains("setTdlibParameters") }
        XCTAssertTrue(sent, "The next client's parameters were taken for a duplicate and never sent")
        XCTAssertFalse(fixture.transport.methods.contains("setTdlibParameters"),
                       "The retired client was sent parameters")
    }

    func testReadyOfARetiredClientDoesNotMakeTheNextClientReadyForPush() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let next = NextClient()
        defer { next.stop() }

        try await handleWhileRetired(["@type": "authorizationStateReady"], in: fixture, next: next)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(fixture.service.push.state.withLock { $0.isReady },
                       "A client that is not authorized yet counted as ready for push registration")
        XCTAssertFalse(next.transport.methods.contains("getMe"),
                       "The sign-in work of the retired client ran against the next one")
    }

    func testPhoneNumberStateOfARetiredClientKeepsThePushRegistrationOfTheNext() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let next = NextClient()
        defer { next.stop() }

        try await handleWhileRetired(["@type": "authorizationStateWaitPhoneNumber"], in: fixture, next: next) {
            fixture.service.push.state.withLock {
                $0.isReady = true
                $0.registeredToken = "ab"
                $0.receiverId = 5
            }
        }

        let (isReady, token, receiver) = fixture.service.push.state.withLock { ($0.isReady, $0.registeredToken, $0.receiverId) }
        XCTAssertTrue(isReady)
        XCTAssertEqual(token, "ab")
        XCTAssertEqual(receiver, 5)
    }

    func testStatesThatEndAClientOfARetiredClientKeepThePushRegistrationOfTheNext() async throws {
        for type in ["authorizationStateClosing", "authorizationStateLoggingOut", "authorizationStateClosed"] {
            let fixture = ScriptedServiceFixture()
            defer { fixture.finish() }
            let next = NextClient()
            defer { next.stop() }

            try await handleWhileRetired(["@type": type], in: fixture, next: next) {
                fixture.service.push.state.withLock {
                    $0.isReady = true
                    $0.registeredToken = "ab"
                }
            }

            let (isReady, token) = fixture.service.push.state.withLock { ($0.isReady, $0.registeredToken) }
            XCTAssertTrue(isReady, "\(type) of a retired client ended the next client's push registration")
            XCTAssertEqual(token, "ab", type)
            XCTAssertEqual(fixture.service.auth.restartCount, 0, "\(type) of a retired client counted as a restart")
        }
    }

    func testOnlineStatusOfTheNextClientSurvivesTheStateOfARetiredOne() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let next = NextClient()
        defer { next.stop() }

        try await handleWhileRetired(["@type": "authorizationStateWaitPhoneNumber"], in: fixture, next: next) {
            // The next client has been told it is online by the time the old state lands.
            fixture.service.resumeFromBackground()
            _ = await self.eventually { next.onlineValues == [true] }
            try await Task.sleep(for: .milliseconds(50))
        }
        fixture.service.resumeFromBackground()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(next.onlineValues, [true], "The old state made the next client forget its online status")
    }

    func testQRLinkOfARetiredClientIsNotReported() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let next = NextClient()
        defer { next.stop() }
        let events = Task { [events = fixture.service.events] () -> [String] in
            var labels: [String] = []
            for await event in events { labels.append(Self.label(event)) }
            return labels
        }

        try await handleWhileRetired(qrLinkState, in: fixture, next: next)
        fixture.service.session.finishEventsForTesting()
        let received = await events.value

        XCTAssertEqual(received, ["generation 1", "generation 2", "chatListSessionStarted"],
                       "A login link of the retired client reached the next session")
        XCTAssertEqual(fixture.service.auth.observedState, .idle)
    }

    // MARK: - Helpers

    /// The client that takes over: scripted, with its receive loop running.
    private final class NextClient: Sendable {
        let transport = ScriptedTDTransport(clientId: 9101)
        let client: TDJsonWrapper

        init() {
            client = transport.wrapper()
            client.startReceiveLoop { _ in }
        }

        func stop() {
            client.stop()
        }

        var onlineValues: [Bool] {
            transport.requests(ofType: "setOption")
                .filter { $0["name"] as? String == "online" }
                .compactMap { ($0["value"] as? [String: Any])?["value"] as? Bool }
        }
    }

    /// Hands `authorizationState` of the fixture's client to the coordinator
    /// and holds its handler right after the check of its client. While it is
    /// held that client is retired and `next` installed and prepared as
    /// `start()` does. `whileHeld` runs after that; then the handler goes on.
    private func handleWhileRetired(
        _ authorizationState: [String: Any],
        in fixture: ScriptedServiceFixture,
        next: NextClient,
        whileHeld: () async throws -> Void = {}
    ) async throws {
        let service = fixture.service
        let source = fixture.client
        let gate = AuthHandlerGate(on: service.auth)
        let handled = Mutex(false)
        // The state goes to the other queue as JSON text, as td_receive hands it over.
        let stateJSON = try String(decoding: JSONSerialization.data(withJSONObject: authorizationState), as: UTF8.self)

        DispatchQueue.global().async {
            service.handleAuthUpdate(TDJSONSample.object(stateJSON), sourceClient: source)
            handled.withLock { $0 = true }
        }
        let inFlight = await eventually { gate.isHolding }
        XCTAssertTrue(inFlight, "The state never reached its handler: the in-flight path is not tested")

        service.session.retire()
        service.installClient(next.client)
        service.auth.prepareForNewClient()
        try await whileHeld()
        gate.letGo()

        let done = await eventually { handled.withLock { $0 } }
        XCTAssertTrue(done, "The handler did not finish")
    }

    private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private static func label(_ event: TDLibEvent) -> String {
        switch event {
        case .clientGenerationChanged(let generation): return "generation \(generation.rawValue)"
        case .chatListSessionStarted: return "chatListSessionStarted"
        case .authStateChanged(let state): return "auth \(state)"
        case .qrCodeLink: return "qrCodeLink"
        default: return "other"
        }
    }
}
