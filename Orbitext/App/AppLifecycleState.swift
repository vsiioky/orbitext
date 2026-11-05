import Foundation

/// What the app is doing with its Telegram client, derived from the facts in
/// `AppLifecycleState`. A logout or a reset dominates everything else: it can
/// outlive a scene change, and a lease can outlive a logout, so the facts are
/// stored apart and this is only their reading.
enum AppLifecyclePhase: Equatable, Sendable {
    case notStarted
    case starting
    case foreground
    /// The scene is not active; `leases` background callbacks still use the client.
    case background(leases: Int)
    case loggingOut
    case resetting
}

/// Why a background callback holds the transport awake.
enum LifecycleLeaseReason: String, Sendable {
    case remotePush
    case backgroundRefresh
    case notificationReply
    case notificationMarkRead
}

/// A change of session that ends the current client's data. Only one runs at a time.
enum SessionTransition: Equatable, Sendable {
    case loggingOut
    case resetting
}

/// What to do with one event of the transport's stream.
enum EventAdmission: Equatable {
    case apply
    /// A generation marker: bookkeeping only, never applied.
    case marker
    /// The event comes from a client the app has ended. Carries the
    /// generation the stream was at, for the log.
    case drop(TDClientGeneration)
}

/// The lifecycle facts of the app as a plain value, so every rule is testable
/// without a transport. `AppLifecycleCoordinator` owns the one instance.
///
/// Phase precedence (`phase`): a session transition first (loggingOut,
/// resetting), then the start (notStarted, starting), then the scene
/// (foreground), otherwise background(leases:). The facts stay apart because
/// they outlive one another: a logout can outlive a scene change, and a lease
/// can outlive a logout.
///
/// Where the flags of the old AppState went:
/// - `isInitialized` is `start` (`isStarted`); AppState keeps a get/set test seam.
/// - `isForegroundActive` is `isSceneActive`.
/// - `backgroundOperations` is `leases`; AppState keeps a read-only test seam.
/// - `isAwaitingLogoutReset` is `transition == .loggingOut` plus the generation
///   floor (`acceptedGeneration`).
/// - `isRestartingAuthorization` is `transition == .resetting`.
/// - `ChatRepository.isInBackgroundState` is still a mirror, written only by
///   the coordinator through `AppLifecycleHost`.
/// - `VoiceManager.isPlaying` reaches the coordinator as
///   `AppLifecycleHost.isTransportPinned`.
/// - `NotificationManager.activeChatId` and `ChatMessageStore.activeChatId`
///   are written by `ChatSessionModel`.
///
/// Still in AppState: `lastBecameActiveTime`, `eventTask`, `awaitedSendResults`
/// and the SyncRequest pipeline.
struct AppLifecycleState: Equatable, Sendable {
    enum Start: Equatable, Sendable {
        case notStarted
        /// The epoch tells a start that was reset from the one that replaced it.
        case starting(epoch: UInt64)
        case started
    }

    private(set) var start = Start.notStarted
    private(set) var isSceneActive = false
    private(set) var leases: [UUID: LifecycleLeaseReason] = [:]
    private(set) var transition: SessionTransition?
    /// Events from clients before this generation belong to ended sessions.
    /// Only rises.
    private(set) var acceptedGeneration = TDClientGeneration.initial
    /// The generation of the last marker the stream delivered.
    private(set) var streamGeneration = TDClientGeneration.initial
    private var nextEpoch: UInt64 = 0

    /// True from the moment a start begins, as `isInitialized` was.
    var isStarted: Bool {
        start != .notStarted
    }

    var phase: AppLifecyclePhase {
        switch transition {
        case .loggingOut?: return .loggingOut
        case .resetting?: return .resetting
        case nil: break
        }
        switch start {
        case .notStarted: return .notStarted
        case .starting: return .starting
        case .started: return isSceneActive ? .foreground : .background(leases: leases.count)
        }
    }

    /// The transport sleeps only when nobody needs it: the scene is away, no
    /// background callback is in flight, no logout or reset is running, and
    /// nothing (voice playback) pins it. A logout signs out on the server
    /// through the receive loop, which a suspended transport does not run.
    func shouldSuspendTransport(pinned: Bool) -> Bool {
        !isSceneActive && leases.isEmpty && transition == nil && !pinned
    }

    // MARK: - Start

    /// Begins a start and returns its epoch, or nil while one began already.
    mutating func beginStart() -> UInt64? {
        guard start == .notStarted else { return nil }
        nextEpoch &+= 1
        start = .starting(epoch: nextEpoch)
        return nextEpoch
    }

    /// A start that was reset meanwhile finishes into nothing.
    mutating func finishStart(epoch: UInt64) {
        guard start == .starting(epoch: epoch) else { return }
        start = .started
    }

    mutating func resetStart() {
        start = .notStarted
    }

    /// Test seam: a client somebody else started.
    mutating func assumeStarted() {
        start = .started
    }

    // MARK: - Scene and leases

    mutating func sceneBecameActive() {
        isSceneActive = true
    }

    mutating func sceneEnteredBackground() {
        isSceneActive = false
    }

    mutating func acquireLease(_ reason: LifecycleLeaseReason) -> UUID {
        let id = UUID()
        leases[id] = reason
        return id
    }

    /// False for a lease that is unknown or already released, so a callback
    /// can only ever give back its own part.
    @discardableResult
    mutating func releaseLease(_ id: UUID) -> Bool {
        leases.removeValue(forKey: id) != nil
    }

    // MARK: - Session transitions

    /// False while another transition runs: a second logout tap, or a logout
    /// during a reset, must not run concurrently.
    mutating func beginTransition(_ next: SessionTransition) -> Bool {
        guard transition == nil else { return false }
        transition = next
        return true
    }

    /// False when `ended` is not the transition that runs.
    @discardableResult
    mutating func endTransition(_ ended: SessionTransition) -> Bool {
        guard transition == ended else { return false }
        transition = nil
        return true
    }

    // MARK: - Event admission

    /// Everything the transport produced up to `generation` belongs to a
    /// session the app has ended. The floor never moves back.
    mutating func retireGenerations(upTo generation: TDClientGeneration) {
        acceptedGeneration = max(acceptedGeneration, generation)
    }

    /// False once the app ended the session that produced `generation`: work
    /// started from one of its events must not show anything any more.
    func isCurrent(_ generation: TDClientGeneration) -> Bool {
        generation >= acceptedGeneration
    }

    /// The stream is FIFO and a marker is yielded in the same step as the
    /// client swap, so the last marker seen names the client of every event
    /// that follows it.
    mutating func admit(_ event: TDLibEvent) -> EventAdmission {
        if case .clientGenerationChanged(let generation) = event {
            streamGeneration = max(streamGeneration, generation)
            return .marker
        }
        return streamGeneration >= acceptedGeneration ? .apply : .drop(streamGeneration)
    }
}
