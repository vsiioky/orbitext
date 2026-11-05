import Foundation
import os

/// Rate-limits TDLib requests: enforces minimum spacing between sends
/// and backs off a method after it hits FLOOD_WAIT.
///
/// Usage:
///   try await throttle.acquireSlot()
///   let result = try await td.send(request)
///   throttle.handleError(error)   // if send threw
///
/// Critical requests (auth, close) bypass the throttle entirely.
actor TDRequestThrottle {
    private var lastSendTime: ContinuousClock.Instant
    private let minSpacing: Duration
    /// A request is parked for at most this long. A longer server limit
    /// (FLOOD_WAIT can be 40+ minutes) fails it at once with that limit, so
    /// callers can tell the user or queue the work instead of hanging.
    private let maxWait: Duration
    private var floodBackoffUntil: ContinuousClock.Instant?
    private(set) var sessionGeneration: UInt64 = 0
    private var methodBackoffUntil: [String: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        minSpacing: Duration = .milliseconds(50),
        maxWait: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.minSpacing = minSpacing
        self.maxWait = maxWait
        self.now = now
        self.sleep = sleep
        lastSendTime = now()
    }

    /// Wait until this request is safe to send.
    /// Multiple concurrent callers are serialized by the actor and each
    /// gets a unique time slot spaced at least `minSpacing` apart.
    func acquireSlot(method: String? = nil, generation: UInt64? = nil, waitsForFullLimit: Bool = false) async throws {
        let expectedGeneration = generation ?? sessionGeneration
        while true {
            try Task.checkCancellation()
            guard expectedGeneration == sessionGeneration else { throw CancellationError() }
            let now = self.now()
            let deadline = [floodBackoffUntil, method.flatMap { methodBackoffUntil[$0] }].compactMap(\.self).max()
            if let deadline, now < deadline {
                let remaining = deadline - now
                guard waitsForFullLimit || remaining <= maxWait else {
                    throw TDError.rateLimited(seconds: Int(remaining.components.seconds) + 1)
                }
                try await sleep(remaining)
                // Actor state may have changed while suspended, including an
                // extension of this deadline. Recheck before clearing or sending.
                continue
            }
            floodBackoffUntil = nil
            if let method { methodBackoffUntil.removeValue(forKey: method) }
            let earliest = lastSendTime + minSpacing
            if now < earliest {
                try await sleep(earliest - now)
                continue
            }
            lastSendTime = now
            return
        }
    }

    /// Respect the full server delay. Push-registration limits are scoped to
    /// that method so an APNs registration failure does not block chat reads.
    @discardableResult
    func reportFloodWait(seconds: Int, method: String? = nil, generation: UInt64? = nil) -> Bool {
        guard seconds > 0, generation == nil || generation == sessionGeneration else { return false }
        let deadline = now() + .seconds(seconds)
        if let method {
            methodBackoffUntil[method] = max(methodBackoffUntil[method] ?? deadline, deadline)
        } else {
            floodBackoffUntil = max(floodBackoffUntil ?? deadline, deadline)
        }
        Logger.network.warning("Throttle: server wait \(seconds)s (scope=\(method ?? "global", privacy: .public))")
        return true
    }

    func remainingBackoff(method: String? = nil) -> Duration {
        let deadline = [floodBackoffUntil, method.flatMap { methodBackoffUntil[$0] }].compactMap(\.self).max()
        return max(.zero, deadline.map { $0 - now() } ?? .zero)
    }

    /// Replacing a client does not lift a server limit on the same account.
    func resetSpacing() {
        lastSendTime = now()
    }

    /// Clear all backoff after a completed local logout, not ordinary restart.
    func reset() {
        sessionGeneration &+= 1
        floodBackoffUntil = nil
        methodBackoffUntil.removeAll()
        lastSendTime = now()
    }
}
