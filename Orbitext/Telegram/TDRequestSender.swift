import Foundation
import os
import Synchronization

/// How the transport's requests reach the current TDLib client.
///
/// A request is `sending`: TDJsonWrapper takes it over, so the caller hands
/// it a dictionary it built for the call and keeps no other reference to.
///
/// Reads TDLib answers from its own database go straight to the client, and
/// identical ones in flight share one request. Everything that may reach
/// Telegram waits for a throttle slot first. A FLOOD_WAIT of any method but
/// registerDevice is kept here for Settings, for the client that got it.
final class TDRequestSender: Sendable {
    /// The latest FLOOD_WAIT shown in Settings.
    struct FloodWait {
        var expiresAt: Date?
        var duration = 0
    }

    let throttle: TDRequestThrottle
    /// Internal for tests. Written only under the session lock while the
    /// client that got the limit is current.
    let floodWait = Mutex(FloodWait())
    private let session: TDClientSession
    private let localRequestDeduper = TDLocalRequestDeduper()

    init(session: TDClientSession, throttle: TDRequestThrottle) {
        self.session = session
        self.throttle = throttle
    }

    /// Returns remaining FLOOD_WAIT seconds, or nil if no active flood wait.
    func currentFloodWaitRemaining() -> Int? {
        floodWait.withLock { floodWait in
            guard let expiresAt = floodWait.expiresAt else { return nil }
            let remaining = Int(expiresAt.timeIntervalSinceNow)
            return remaining > 0 ? remaining : nil
        }
    }

    /// For a wiped session: its limits are not the next account's.
    func forgetFloodWait() {
        floodWait.withLock { $0 = FloodWait() }
    }

    /// Send a local TDLib request WITHOUT throttling.
    /// Use for methods that only query TDLib's local database (getChat, getUser, getMessage)
    /// and never hit Telegram servers. These are safe to call rapidly.
    func localSend(_ request: sending [String: Any]) async throws -> [String: Any] {
        guard let td = session.client else { throw TelegramServiceError.notStarted }
        return try await td.send(request)
    }

    /// A local request that may take as long as TDLib needs, like one that
    /// works through every file on the device: its caller bounds the wait by
    /// cancelling. A timeout would report a failure while TDLib is still at it.
    func localSendWithoutTimeout(_ request: sending [String: Any]) async throws -> [String: Any] {
        guard let td = session.client else { throw TelegramServiceError.notStarted }
        return try await td.sendWithoutTimeout(request)
    }

    /// Coalesce identical local TDLib database reads that are already in flight.
    ///
    /// These requests are intentionally not throttled because TDLib serves them
    /// from its local database, but duplicate getChat/getUser/getMessage bursts
    /// still compete with the update drain and inflate telemetry. Coalescing
    /// preserves behavior while avoiding redundant work.
    func dedupedLocalSend(_ request: [String: Any], key: String) async throws -> [String: Any] {
        // The callers that share it wait for one request, so it is shared
        // between tasks: wrapped as TDLib JSON, which nobody mutates.
        let shared = TDResponse(dict: request)
        return try await localRequestDeduper.run(key: key) { [weak self] in
            guard let self else { throw TelegramServiceError.notStarted }
            let result = try await self.localSend(shared.dict)
            return TDResponse(dict: result)
        }.dict
    }

    /// Send a TDLib request with rate limiting.
    /// All non-critical requests should use this instead of `td.send()` directly.
    func throttledSend(_ request: sending [String: Any]) async throws -> [String: Any] {
        guard let td = session.client else { throw TelegramServiceError.notStarted }
        return try await throttledSend(request, using: td)
    }

    /// A throttled request that may wait as long as TDLib takes to answer, like
    /// a synchronous download: its caller bounds the wait by cancelling.
    /// `prepare` edits the request after the throttle wait, right before it
    /// is sent.
    func throttledSendWithoutTimeout(
        _ request: sending [String: Any],
        prepare: @escaping @Sendable (inout [String: Any]) -> Void
    ) async throws -> [String: Any] {
        guard let td = session.client else { throw TelegramServiceError.notStarted }
        return try await throttledSend(request, using: td, timesOut: false, prepare: prepare)
    }

    /// The throttled send to one client. `beforeSend` runs after the
    /// throttle wait and may still call the request off by throwing.
    func throttledSend(
        _ request: sending [String: Any],
        using td: TDJsonWrapper,
        waitsForFullLimit: Bool = false,
        timesOut: Bool = true,
        beforeSend: (@Sendable () throws -> Void)? = nil,
        prepare: (@Sendable (inout [String: Any]) -> Void)? = nil
    ) async throws -> [String: Any] {
        var request = request
        let requestType = request["@type"] as? String ?? "unknown"
        let generation = await throttle.sessionGeneration
        let start = ContinuousClock.now
        if AppLogSettings.verboseTDTransport {
            Logger.network.debug("-> \(requestType, privacy: .public) waiting for throttle slot")
        }
        do {
            try await throttle.acquireSlot(method: requestType, generation: generation, waitsForFullLimit: waitsForFullLimit)
            try Task.checkCancellation()
            guard session.isCurrent(td) else { throw TDError.clientClosed }
            try beforeSend?()
            prepare?(&request)
            let throttleWait = ContinuousClock.now - start
            if AppLogSettings.verboseTDTransport {
                Logger.network.debug("-> \(requestType, privacy: .public) sending (throttle wait: \(throttleWait, privacy: .public))")
            }
            let result = timesOut ? try await td.send(request) : try await td.sendWithoutTimeout(request)
            let elapsed = ContinuousClock.now - start
            let resultType = result["@type"] as? String ?? "unknown"
            if AppLogSettings.verboseTDTransport {
                Logger.network.debug("<- \(requestType, privacy: .public) ok [\(resultType, privacy: .public)] (\(elapsed, privacy: .public))")
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let elapsed = ContinuousClock.now - start
            Logger.network.error("<- \(requestType, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public) (\(elapsed, privacy: .public))")
            if !Task.isCancelled, session.isCurrent(td), let seconds = (error as? TDError)?.floodWaitSeconds {
                // Telegram limits a method, not the account: a getChats limit
                // must not hold back sending a message or registering a push.
                let accepted = await throttle.reportFloodWait(seconds: seconds, method: requestType, generation: generation)
                if accepted, requestType != "registerDevice" {
                    recordFloodWait(seconds: seconds, for: td)
                }
            }
            throw error
        }
    }

    /// Only while `td` is current: a limit of the retired client must not
    /// land after a wipe has forgotten its limits.
    private func recordFloodWait(seconds: Int, for td: TDJsonWrapper) {
        session.ifCurrent(td) {
            floodWait.withLock { floodWait in
                let expiry = Date().addingTimeInterval(TimeInterval(seconds))
                if expiry > (floodWait.expiresAt ?? .distantPast) {
                    floodWait.duration = seconds
                    floodWait.expiresAt = expiry
                }
            }
        }
    }
}

private actor TDLocalRequestDeduper {
    private var inFlight: [String: Task<TDResponse, any Error>] = [:]

    func run(
        key: String,
        operation: @escaping @Sendable () async throws -> TDResponse
    ) async throws -> TDResponse {
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task { try await operation() }
        inFlight[key] = task
        do {
            let response = try await task.value
            inFlight[key] = nil
            return response
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}
