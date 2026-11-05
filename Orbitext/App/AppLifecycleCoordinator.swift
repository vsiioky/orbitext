import Foundation
import os

/// What the coordinator needs from the app around it.
@MainActor
protocol AppLifecycleHost: AnyObject {
    /// Everything that has to exist before the client emits its first event:
    /// the event loop, notification categories, the reconnect hook. The
    /// coordinator starts the transport right after it returns.
    func prepareForClientStart() async
    /// Something other than the scene and the leases needs the transport
    /// awake (voice playback).
    var isTransportPinned: Bool { get }
    /// The chat repository mirrors the scene for its notification and widget
    /// decisions; every change of the scene or of a lease updates it.
    func transportBackgroundStateDidChange(_ isInBackground: Bool)
}

/// How one kind of background entry point uses the client: whether it may
/// start it, what it needs before it runs, and how it treats cancellation.
struct LeasePolicy: Equatable, Sendable {
    /// A cold-launched notification action starts the client itself.
    var startsClient: Bool
    /// Skip, without waking the transport, unless the account is ready.
    var requiresAuthorization: Bool
    /// A callback the system cancelled (a spent time budget) does no more work.
    var skipsWhenCancelled: Bool
    /// Wait this long for the account to become ready, after resuming the transport.
    var authorizationTimeout: TimeInterval?

    /// A push never cold-starts the client and runs before the account is
    /// ready: it only hands the payload to TDLib.
    ///
    /// Not starting is deliberate since 20770de (a background callback must
    /// not boot TDLib) and the two DoesNotColdStart tests pin it. What is not
    /// known is whether, before 2769b43, the loading screen's `.task` started
    /// the client anyway when the system relaunched the app in the background
    /// (if SwiftUI builds that screen there). It was never checked on a watch,
    /// so a cold wake may now find nothing started: it logs "skipped:
    /// notStarted" and returns .noData. Check this on hardware
    /// before relying on pushes while the app is not running.
    static let remotePush = LeasePolicy(startsClient: false, requiresAuthorization: false,
                                        skipsWhenCancelled: true, authorizationTimeout: nil)
    /// Like `remotePush`, a refresh never cold-starts the client.
    static let backgroundRefresh = LeasePolicy(startsClient: false, requiresAuthorization: true,
                                               skipsWhenCancelled: true, authorizationTimeout: nil)

    /// Reply and Mark as Read are the user's own words: they start the client,
    /// wait for it, and run even when the system cancelled the callback while
    /// the account was already ready.
    static func notificationAction(readyTimeout: TimeInterval) -> LeasePolicy {
        LeasePolicy(startsClient: true, requiresAuthorization: false,
                    skipsWhenCancelled: false, authorizationTimeout: readyTimeout)
    }
}

enum LeaseSkipReason: Equatable, Sendable {
    case cancelled
    case notStarted
    case notAuthorized
    /// The account is signed out: work for it must not reach the next session.
    case signedOut
    case timedOut
}

enum LeaseOutcome<Value> {
    case ran(Value)
    case skipped(LeaseSkipReason)
}

extension LeaseOutcome: Equatable where Value: Equatable {}
extension LeaseOutcome: Sendable where Value: Sendable {}

/// Owns the lifecycle facts of the app (`AppLifecycleState`) and what the
/// transport has to do about them. AppState keeps the event switch, the sync
/// pipeline and the notification business logic; it asks this class whether a
/// session change may begin, and whether an event may be applied.
@MainActor
final class AppLifecycleCoordinator {
    private(set) var state = AppLifecycleState()
    private let service: TelegramServiceProtocol
    private let authManager: AuthManager
    private let networkMonitor: NetworkMonitor

    /// Set by AppState at the end of its init, once everything it exposes exists.
    weak var host: (any AppLifecycleHost)?
    private var startTask: (epoch: UInt64, task: Task<Void, Never>)?

    var phase: AppLifecyclePhase { state.phase }

    init(service: TelegramServiceProtocol, authManager: AuthManager, networkMonitor: NetworkMonitor) {
        self.service = service
        self.authManager = authManager
        self.networkMonitor = networkMonitor
    }

    // MARK: - Start

    /// Starts the client once, whoever asks first: the scene, a notification
    /// action, or a view. Later callers wait for the start in flight, so they
    /// can rely on it. The start is its own task, so cancelling the first
    /// caller cannot leave a half-started client.
    func ensureStarted() async {
        if let startTask {
            await startTask.task.value
            return
        }
        guard let epoch = state.beginStart() else { return }
        guard host != nil else {
            assertionFailure("AppLifecycleCoordinator needs its host to start the client")
            state.resetStart()
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.host?.prepareForClientStart()
            // A reset meanwhile gave the start to a replacement.
            guard let self, self.state.start == .starting(epoch: epoch) else { return }
            await self.service.start()
            self.state.finishStart(epoch: epoch)
            // A scene change during the start reached no client; apply it now.
            self.suspendIfIdle()
            if self.startTask?.epoch == epoch {
                self.startTask = nil
            }
        }
        startTask = (epoch, task)
        await task.value
    }

    /// The next ensureStarted starts the client again (after a destructive
    /// reset). A start still in flight finishes into nothing.
    func resetStart() {
        state.resetStart()
        startTask = nil
    }

    /// Test seam: a client somebody else started.
    func assumeStarted() {
        state.assumeStarted()
        startTask = nil
    }

    // MARK: - Scene

    func sceneDidBecomeActive() {
        state.sceneBecameActive()
        host?.transportBackgroundStateDidChange(false)
        service.resumeFromBackground()
        networkMonitor.resume()
        RemotePushCoordinator.shared.registerForRemoteNotifications()
    }

    func sceneDidEnterBackground() {
        state.sceneEnteredBackground()
        host?.transportBackgroundStateDidChange(true)
        suspendIfIdle()
    }

    // MARK: - Leases

    /// Runs `body` as a background entry point (a push, a refresh, a
    /// notification action) that holds the transport awake for the whole
    /// body, even across scene changes. Completion releases only this
    /// callback's part, so one callback ending cannot put the transport to
    /// sleep under another. The policy decides what the entry point needs
    /// first; a skip returns the reason without running `body`.
    ///
    /// 1. A cancelled caller is skipped before a lease is taken, if the policy says so.
    /// 2. The lease is taken and the repository is marked as background (unless the scene is active).
    /// 3. The client is started if the policy allows it, or the entry point is skipped as not started.
    /// 4. Cancellation is checked again, then the account is checked if required.
    /// 5. The transport is resumed, and the policy's wait for the account runs.
    func withLease<T>(
        _ reason: LifecycleLeaseReason,
        policy: LeasePolicy,
        _ body: @MainActor () async -> T
    ) async -> LeaseOutcome<T> {
        if policy.skipsWhenCancelled, Task.isCancelled { return .skipped(.cancelled) }
        let lease = acquireLease(reason)
        defer { releaseLease(lease) }

        if policy.startsClient {
            await ensureStarted()
        } else if !state.isStarted {
            return .skipped(.notStarted)
        }
        if policy.skipsWhenCancelled, Task.isCancelled { return .skipped(.cancelled) }
        if policy.requiresAuthorization, authManager.authState != .ready { return .skipped(.notAuthorized) }

        service.resumeFromBackground()
        if let timeout = policy.authorizationTimeout,
           let skip = await waitForAuthorization(timeout: timeout) {
            return .skipped(skip)
        }
        let result = await body()
        return .ran(result)
    }

    private func acquireLease(_ reason: LifecycleLeaseReason) -> UUID {
        let id = state.acquireLease(reason)
        host?.transportBackgroundStateDidChange(!state.isSceneActive)
        return id
    }

    private func releaseLease(_ id: UUID) {
        guard state.releaseLease(id) else { return }
        suspendIfIdle()
    }

    /// Nil once the account is ready; otherwise why it will not be.
    private func waitForAuthorization(timeout: TimeInterval) async -> LeaseSkipReason? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(max(0, timeout))
        while true {
            switch authManager.authState {
            case .ready:
                return nil
            case .waitPhoneNumber, .waitOtherDeviceConfirmation, .waitCode, .waitPassword:
                return .signedOut
            case .idle, .closing, .error:
                break
            }
            guard clock.now < deadline else { return .timedOut }
            do {
                try await clock.sleep(until: min(deadline, clock.now + .milliseconds(50)))
            } catch {
                return .cancelled
            }
        }
    }

    private func suspendIfIdle() {
        guard state.shouldSuspendTransport(pinned: host?.isTransportPinned ?? false) else { return }
        networkMonitor.pause()
        service.suspendForBackground()
    }

    // MARK: - Session transitions

    /// False while another logout or reset runs: the caller must not start.
    func beginTransition(_ transition: SessionTransition) -> Bool {
        state.beginTransition(transition)
    }

    /// The transport stayed awake for the transition; if the scene left
    /// meanwhile, nobody else would put it to sleep now.
    func endTransition(_ transition: SessionTransition) {
        guard state.endTransition(transition) else { return }
        suspendIfIdle()
    }

    // MARK: - Client generations

    /// Call right after the app ended a session (a logout or a destructive
    /// reset succeeded), with no suspension point in between: every event the
    /// transport produced for the client that just ended is dropped when the
    /// stream reaches it, and the next client's events apply.
    func retireCurrentClient() {
        state.retireGenerations(upTo: service.clientGeneration)
    }

    /// Whether `event` is for AppState to apply. Generation markers are
    /// bookkeeping, and events of a retired client are dropped.
    func admit(_ event: TDLibEvent) -> Bool {
        switch state.admit(event) {
        case .apply:
            return true
        case .marker:
            return false
        case .drop(let generation):
            // The generation only: the payload may be a message.
            Logger.app.debug("Dropping an event of an ended client session (stream at \(generation.description, privacy: .public))")
            return false
        }
    }
}
