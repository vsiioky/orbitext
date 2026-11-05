import XCTest
@testable import OrbitextWatch

/// The lifecycle rules as a plain value: no transport, no app state.
final class AppLifecycleStateTests: XCTestCase {
    private let gen1 = TDClientGeneration.initial.next()
    private var gen2: TDClientGeneration { gen1.next() }

    // MARK: - Event admission

    func testMarkerAdvancesTheCursorAndIsNotApplied() {
        var state = AppLifecycleState()

        let admission = state.admit(.clientGenerationChanged(gen2))

        XCTAssertEqual(admission, .marker)
        XCTAssertEqual(state.streamGeneration, gen2)
    }

    func testEventsBeforeTheRetiredGenerationsMarkerAreDropped() {
        var state = AppLifecycleState()
        _ = state.admit(.clientGenerationChanged(gen1))
        state.retireGenerations(upTo: gen2)

        XCTAssertEqual(state.admit(.chatListSessionStarted), .drop(gen1),
                       "A late event of the ended client must not reach the next account")
        XCTAssertEqual(state.admit(.clientGenerationChanged(gen2)), .marker)
        XCTAssertEqual(state.admit(.chatListSessionStarted), .apply)
    }

    func testEventsOfTheRetiredGenerationItselfAreApplied() {
        var state = AppLifecycleState()
        _ = state.admit(.clientGenerationChanged(gen1))

        state.retireGenerations(upTo: gen1)

        XCTAssertEqual(state.admit(.chatListSessionStarted), .apply)
    }

    func testFloorNeverMovesBack() {
        var state = AppLifecycleState()

        state.retireGenerations(upTo: gen2)
        state.retireGenerations(upTo: gen1)

        XCTAssertEqual(state.acceptedGeneration, gen2)
    }

    func testStreamCursorNeverMovesBack() {
        var state = AppLifecycleState()
        _ = state.admit(.clientGenerationChanged(gen2))

        _ = state.admit(.clientGenerationChanged(gen1))

        XCTAssertEqual(state.streamGeneration, gen2)
    }

    func testWithoutMarkersEveryEventIsAdmitted() {
        // A transport with one client for life (the mock) never sends one.
        var state = AppLifecycleState()

        XCTAssertEqual(state.admit(.chatListSessionStarted), .apply)
        XCTAssertEqual(state.admit(.authStateChanged(.closing)), .apply)
    }

    func testRetiringTheInitialGenerationDropsNothing() {
        var state = AppLifecycleState()

        state.retireGenerations(upTo: .initial)

        XCTAssertEqual(state.admit(.chatListSessionStarted), .apply)
    }

    // MARK: - Session transitions

    func testOnlyOneSessionTransitionAtATime() {
        var state = AppLifecycleState()

        XCTAssertTrue(state.beginTransition(.loggingOut))
        XCTAssertFalse(state.beginTransition(.loggingOut), "A second logout tap")
        XCTAssertFalse(state.beginTransition(.resetting), "A reset during a logout")

        state.endTransition(.loggingOut)

        XCTAssertNil(state.transition)
        XCTAssertTrue(state.beginTransition(.resetting))
    }

    func testEndingAnotherTransitionIsIgnored() {
        var state = AppLifecycleState()
        XCTAssertTrue(state.beginTransition(.resetting))

        state.endTransition(.loggingOut)

        XCTAssertEqual(state.transition, .resetting)
    }

    // MARK: - Phase

    func testPhaseFollowsTheStartAndTheScene() {
        var state = AppLifecycleState()
        XCTAssertEqual(state.phase, .notStarted)
        XCTAssertFalse(state.isStarted)

        let epoch = state.beginStart()
        XCTAssertEqual(state.phase, .starting)
        XCTAssertTrue(state.isStarted, "Started means the start began, as isInitialized did")

        state.finishStart(epoch: epoch ?? 0)
        XCTAssertEqual(state.phase, .background(leases: 0))

        state.sceneBecameActive()
        XCTAssertEqual(state.phase, .foreground)

        state.sceneEnteredBackground()
        XCTAssertEqual(state.phase, .background(leases: 0))
    }

    func testTransitionDominatesPhase() {
        var state = AppLifecycleState()
        state.assumeStarted()
        _ = state.acquireLease(.remotePush)
        _ = state.acquireLease(.backgroundRefresh)
        XCTAssertEqual(state.phase, .background(leases: 2))

        XCTAssertTrue(state.beginTransition(.loggingOut))
        XCTAssertEqual(state.phase, .loggingOut)

        state.endTransition(.loggingOut)
        XCTAssertTrue(state.beginTransition(.resetting))
        state.sceneBecameActive()
        XCTAssertEqual(state.phase, .resetting)
    }

    func testBackgroundPhaseCountsLeases() {
        var state = AppLifecycleState()
        state.assumeStarted()

        let first = state.acquireLease(.notificationReply)
        let second = state.acquireLease(.notificationMarkRead)
        XCTAssertEqual(state.phase, .background(leases: 2))

        state.releaseLease(first)
        XCTAssertEqual(state.phase, .background(leases: 1))

        state.releaseLease(second)
        XCTAssertEqual(state.phase, .background(leases: 0))
    }

    // MARK: - Start

    func testBeginStartIsRefusedWhileOneIsKnown() {
        var state = AppLifecycleState()
        let epoch = state.beginStart()
        XCTAssertNotNil(epoch)

        XCTAssertNil(state.beginStart(), "A start is already running")
        state.finishStart(epoch: epoch ?? 0)
        XCTAssertNil(state.beginStart(), "A started client is not started again")
    }

    func testStaleFinishStartAfterResetIsIgnored() throws {
        var state = AppLifecycleState()
        let first = try XCTUnwrap(state.beginStart())
        state.resetStart()
        let second = try XCTUnwrap(state.beginStart())
        XCTAssertNotEqual(first, second)

        state.finishStart(epoch: first)
        XCTAssertEqual(state.phase, .starting, "The reset start must not complete the new one")

        state.finishStart(epoch: second)
        XCTAssertEqual(state.phase, .background(leases: 0))
    }

    func testResetStartAllowsANewStart() {
        var state = AppLifecycleState()
        state.assumeStarted()

        state.resetStart()

        XCTAssertFalse(state.isStarted)
        XCTAssertNotNil(state.beginStart())
    }

    // MARK: - Leases and the transport

    func testTransportSuspendsOnlyWhenSceneInactiveNoLeasesAndNotPinned() {
        for sceneActive in [false, true] {
            for hasLease in [false, true] {
                for pinned in [false, true] {
                    var state = AppLifecycleState()
                    if sceneActive { state.sceneBecameActive() }
                    if hasLease { _ = state.acquireLease(.remotePush) }

                    let expected = !sceneActive && !hasLease && !pinned
                    XCTAssertEqual(
                        state.shouldSuspendTransport(pinned: pinned), expected,
                        "scene active \(sceneActive), lease \(hasLease), pinned \(pinned)"
                    )
                }
            }
        }
    }

    func testTransportStaysAwakeWhileASessionTransitionRuns() {
        for transition in [SessionTransition.loggingOut, .resetting] {
            var state = AppLifecycleState()
            XCTAssertTrue(state.shouldSuspendTransport(pinned: false), "Nothing holds the transport")

            XCTAssertTrue(state.beginTransition(transition))
            XCTAssertFalse(state.shouldSuspendTransport(pinned: false),
                           "\(transition) needs the receive loop to reach the server")

            state.endTransition(transition)
            XCTAssertTrue(state.shouldSuspendTransport(pinned: false), "The hold ends with the transition")
        }
    }

    func testEndingATransitionReportsWhetherOneEnded() {
        var state = AppLifecycleState()
        XCTAssertTrue(state.beginTransition(.loggingOut))

        XCTAssertFalse(state.endTransition(.resetting), "Another transition is running")
        XCTAssertTrue(state.endTransition(.loggingOut))
        XCTAssertFalse(state.endTransition(.loggingOut), "A transition ends once")
    }

    func testReleasingAnUnknownOrReleasedLeaseReturnsFalse() {
        var state = AppLifecycleState()
        let lease = state.acquireLease(.backgroundRefresh)

        XCTAssertFalse(state.releaseLease(UUID()))
        XCTAssertTrue(state.releaseLease(lease))
        XCTAssertFalse(state.releaseLease(lease), "A callback gives back its own part once")
        XCTAssertTrue(state.leases.isEmpty)
    }
}
