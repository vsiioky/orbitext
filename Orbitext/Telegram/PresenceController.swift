import Foundation
import os
import Synchronization

/// The account's online status: online while the app is in the foreground,
/// offline in the background, where the receive loop also pauses once TDLib
/// has taken the offline status.
///
/// A change goes to TDLib at once and replaces the request still waiting for
/// its answer, so TDLib ends on the status sent last. The receive loop
/// follows the status: it is paused or resumed in the same critical section
/// that reads or writes the wanted status. A pause decided under the lock
/// and applied after it could land after the app came back to the foreground
/// and resumed the loop, and a paused loop never reads the answer to the
/// online status sent next.
///
/// A status TDLib refuses (a flood wait, say) is asked for again once the
/// wait is over, up to `maxRetries` times in a row, so the account does not
/// stay online in the background or offline in the foreground until the next
/// change of scene.
///
/// The state lock is held around `TDJsonWrapper.pause` and `resume`, which
/// take only the wrapper's own leaf locks and call nothing back. The session
/// is read before the lock, never under it.
final class PresenceController: Sendable {
    private struct State {
        /// What TDLib last applied; nil until a status went out.
        var current: Bool?
        /// The status being sent.
        var pending: Bool?
        var desired = true
        var task: Task<Void, Never>?
        /// Refusals of the wanted status since it last changed or applied.
        var failures = 0
    }

    /// Automatic asks after refusals, before waiting for the next change.
    private static let maxRetries = 5
    /// The wait before asking again when the refusal names no wait.
    private static let defaultRetryDelay: Duration = .seconds(5)

    private let state = Mutex(State())
    private let session: TDClientSession
    private let requests: TDRequestSender
    private let beforePause = Mutex<(@Sendable () -> Void)?>(nil)

    init(session: TDClientSession, requests: TDRequestSender) {
        self.session = session
        self.requests = requests
    }

    func goOffline() {
        want(online: false, client: session.client)
    }

    func goOnline() {
        want(online: true, client: session.client)
    }

    /// A client that closes or starts over has applied no status yet. A new
    /// session starts wanting to be online.
    func forgetAppliedStatus(wantingOnline: Bool) {
        state.withLock { state in
            state.current = nil
            state.pending = nil
            state.failures = 0
            if wantingOnline { state.desired = true }
        }
    }

    private func want(online isOnline: Bool, client: TDJsonWrapper?) {
        let superseded = state.withLock { state -> Task<Void, Never>? in
            state.desired = isOnline
            state.failures = 0
            // The loop runs before online goes out, so its answer is read.
            if isOnline { client?.resume() }
            return reconcile(&state, client: client)
        }
        superseded?.cancel()
    }

    /// Brings TDLib to the status wanted now: nothing to send when it has it
    /// (offline: pause at once), else a request that replaces the one in
    /// flight. Returns the replaced task, which the caller cancels once the
    /// lock is released. Called with the lock held.
    private func reconcile(_ state: inout State, client: TDJsonWrapper?) -> Task<Void, Never>? {
        let wanted = state.desired
        if state.current == wanted, state.pending == nil {
            if !wanted { pause(client) }
            return nil
        }
        state.pending = wanted
        let superseded = state.task
        state.task = Task { [weak self] in
            await self?.send(wanted)
        }
        return superseded
    }

    private func send(_ isOnline: Bool) async {
        do {
            _ = try await requests.throttledSend([
                "@type": "setOption",
                "name": "online",
                "value": [
                    "@type": "optionValueBoolean",
                    "value": isOnline
                ] as [String: Any]
            ])
        } catch TelegramServiceError.notStarted {
            return
        } catch is CancellationError {
            return
        } catch {
            Logger.tdlib.warning("setOption(online=\(isOnline, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            // TDLib did not take the status: keep what it last applied and
            // leave the loop as it is, then ask again once the wait is over.
            await retryAfterRefusal(of: isOnline, error: error)
            return
        }
        guard !Task.isCancelled else { return }

        let client = session.client
        let superseded = state.withLock { state -> Task<Void, Never>? in
            state.current = isOnline
            state.pending = nil
            state.failures = 0
            // Wanted as sent: offline now pauses the loop, online has
            // nothing left to do.
            guard state.desired != isOnline else {
                if !isOnline { pause(client) }
                return nil
            }
            // The status changed while this one was in flight: send the
            // status wanted now.
            if state.desired { client?.resume() }
            return reconcile(&state, client: client)
        }
        superseded?.cancel()
    }

    /// Asks again for a refused status unless it was replaced meanwhile.
    /// The caller is the task that sent it; a newer ask cancels the wait.
    private func retryAfterRefusal(of isOnline: Bool, error: any Error) async {
        let closed: Bool
        if case TDError.clientClosed = error { closed = true } else { closed = false }
        let shouldRetry = state.withLock { state -> Bool in
            // Replaced while in flight: the newer request owns the outcome.
            guard state.pending == isOnline else { return false }
            state.pending = nil
            state.failures += 1
            return !closed && state.desired == isOnline && state.failures <= Self.maxRetries
        }
        guard shouldRetry else { return }
        let delay = (error as? TDError)?.floodWaitSeconds.map { Duration.seconds($0) } ?? Self.defaultRetryDelay
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        let client = session.client
        let superseded = state.withLock { state -> Task<Void, Never>? in
            // The status changed or applied while waiting.
            guard state.desired == isOnline, state.pending == nil, state.current != isOnline else { return nil }
            return reconcile(&state, client: client)
        }
        superseded?.cancel()
    }

    /// Called with the state lock held, so the pause belongs to the status
    /// that was just read.
    private func pause(_ client: TDJsonWrapper?) {
        beforePause.withLock { $0 }?()
        client?.pause()
    }

    // MARK: - Test seams

    /// Runs right before the receive loop is paused, where the pause is
    /// decided.
    func setBeforePauseForTesting(_ hook: (@Sendable () -> Void)?) {
        beforePause.withLock { $0 = hook }
    }
}
