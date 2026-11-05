import Dispatch
import Synchronization
@testable import OrbitextWatch

/// Holds the first authorization state the coordinator handles, once its
/// handler is past the check of its client, until the test lets it go. The
/// test then changes what the handler is about to act on with a state in
/// flight, and no sleep has to guess that the handler got that far.
final class AuthHandlerGate: Sendable {
    private let inFlight = Mutex(false)
    private let didHold = Mutex(false)
    private let release = DispatchSemaphore(value: 0)

    init(on auth: AuthCoordinator) {
        auth.setAfterClientCheckForTesting { [self] in hold() }
    }

    /// A handler is waiting in the gate.
    var isHolding: Bool { inFlight.withLock { $0 } }

    func letGo() {
        release.signal()
    }

    private func hold() {
        let isFirst = didHold.withLock { didHold -> Bool in
            defer { didHold = true }
            return !didHold
        }
        guard isFirst else { return }
        inFlight.withLock { $0 = true }
        // Bounded, so a test that fails before it lets go does not hang.
        _ = release.wait(timeout: .now() + 10)
    }
}
