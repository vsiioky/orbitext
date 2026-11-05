import Foundation
import Synchronization

/// Serializes client replacement and database access across suspension points.
/// A lease releases synchronously, including when its owning task is canceled.
final class TDClientLifecycleGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: TDClientLifecycleGate?

        fileprivate init(gate: TDClientLifecycleGate) { self.gate = gate }

        func release() {
            let owner = lock.withLock {
                let owner = gate
                gate = nil
                return owner
            }
            owner?.release()
        }

        deinit { release() }
    }

    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Lease, any Error>)] = []

    var waitingCountForTesting: Int { lock.withLock { waiters.count } }

    func acquire() async throws -> Lease {
        let id = UUID()
        let lease: Lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Lease, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if isHeld {
                        waiters.append((id, continuation))
                        return nil
                    }
                    isHeld = true
                    return .success(Lease(gate: self))
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
        guard !Task.isCancelled else {
            lease.release()
            throw CancellationError()
        }
        return lease
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter: CheckedContinuation<Lease, any Error>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func release() {
        let next: CheckedContinuation<Lease, any Error>? = lock.withLock {
            if !waiters.isEmpty { return waiters.removeFirst().continuation }
            isHeld = false
            return nil
        }
        next?.resume(returning: Lease(gate: self))
    }
}

/// The native client the transport talks to, and its lifetime: which client
/// is current, its generation, the exclusive transition that replaces or
/// retires it, the account it is signed in as, and the event stream every
/// part of the transport reports into.
///
/// Its lock is the outermost lock of the transport. `ifCurrent` and
/// `withCurrentClient` run their body under it, and that body may take the
/// lock of a component (auth, push, presence, flood wait), one after the
/// other; no component calls into the session while it holds its own lock.
final class TDClientSession: Sendable {
    let events: AsyncStream<TDLibEvent>
    private let continuation: AsyncStream<TDLibEvent>.Continuation
    /// Held for every install, close, retirement and database removal.
    let lifecycleGate = TDClientLifecycleGate()

    private struct State {
        var client: TDJsonWrapper?
        /// Advanced, with a marker, whenever a client is installed or retired.
        /// Test fixtures that replace the client directly leave it alone.
        var generation = TDClientGeneration.initial
        var isTransitionInProgress = false
        /// The account the current client is signed in as; 0 while unknown.
        var accountUserID: Int64 = 0
    }

    private let state = Mutex(State())

    init() {
        let (stream, continuation) = AsyncStream<TDLibEvent>.makeStream()
        events = stream
        self.continuation = continuation
    }

    /// Every event goes out through here: the stream is FIFO, and the
    /// generation markers rely on one writer order. Takes no lock, so it may
    /// be called under any of them.
    func emit(_ event: TDLibEvent) {
        continuation.yield(event)
    }

    var client: TDJsonWrapper? {
        state.withLock { $0.client }
    }

    var generation: TDClientGeneration {
        state.withLock { $0.generation }
    }

    func isCurrent(_ client: TDJsonWrapper) -> Bool {
        state.withLock { $0.client === client }
    }

    /// Runs `body` only while `client` is current, under the session lock, so
    /// no install or retirement can slip between the check and `body`. Nil
    /// when `client` is not current. `body` must not call into the session.
    @discardableResult
    func ifCurrent<T: Sendable>(_ client: TDJsonWrapper, _ body: () -> T) -> T? {
        state.withLock { state in
            guard state.client === client else { return nil }
            return body()
        }
    }

    /// Runs `body` with the current client, under the session lock, for work
    /// that has to be decided for that client and no other.
    func withCurrentClient<T: Sendable>(_ body: (TDJsonWrapper?) -> T) -> T {
        state.withLock { body($0.client) }
    }

    /// Makes `client` current and starts its generation and chat list session.
    func install(_ client: TDJsonWrapper) {
        state.withLock { state in
            state.client = client
            state.generation = state.generation.next()
            continuation.yield(.clientGenerationChanged(state.generation))
            continuation.yield(.chatListSessionStarted)
        }
    }

    /// Call only after the client's close returned (`TDJsonWrapper.stopAndWait`):
    /// its drain barrier has run every update callback of the old client, and
    /// all of them emit synchronously, so every event of the old client is in
    /// the stream before this marker.
    func retire() {
        state.withLock { state in
            guard state.client != nil else { return }
            state.client = nil
            state.generation = state.generation.next()
            continuation.yield(.clientGenerationChanged(state.generation))
        }
    }

    // MARK: - Transitions

    var isTransitionInProgress: Bool {
        state.withLock { $0.isTransitionInProgress }
    }

    /// Waits for the lifecycle gate; the caller ends the transition with
    /// `endTransition`, on every path.
    func beginTransition() async throws -> TDClientLifecycleGate.Lease {
        let lease = try await lifecycleGate.acquire()
        state.withLock { $0.isTransitionInProgress = true }
        return lease
    }

    func endTransition(_ lease: TDClientLifecycleGate.Lease) {
        state.withLock { $0.isTransitionInProgress = false }
        lease.release()
    }

    // MARK: - Account identity

    /// The account the current client is signed in as; 0 while unknown.
    var accountUserID: Int64 {
        get { state.withLock { $0.accountUserID } }
        set { state.withLock { $0.accountUserID = newValue } }
    }

    /// A getMe answer counts only while the client that gave it is current
    /// and open: a delayed answer cannot restore an identity after native
    /// shutdown.
    @discardableResult
    func setAccountUserID(_ id: Int64, reportedBy client: TDJsonWrapper) -> Bool {
        state.withLock { state in
            guard state.client === client, !client.isNativeClosed else { return false }
            state.accountUserID = id
            return true
        }
    }

    // MARK: - Test seams

    /// For fixtures that hand the transport a scripted client: makes it
    /// current without a generation marker, as if it had always been.
    func replaceClientForTesting(_ client: TDJsonWrapper?) {
        state.withLock { $0.client = client }
    }

    /// Ends the event stream, so a test can read it to the end.
    func finishEventsForTesting() {
        continuation.finish()
    }
}
