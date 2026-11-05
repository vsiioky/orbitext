import Foundation
import os

/// Wrapper to make `[String: Any]` Sendable for TDLib FFI layer.
/// Thread safety is guaranteed by NSLock in TDJsonWrapper.
struct TDResponse: @unchecked Sendable {
    let dict: [String: Any]
}

/// Cancellation-aware shared completion used for native close and callback drain.
private final class TDCompletionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    var isClosed: Bool { lock.withLock { closed } }

    func complete() {
        let pending = lock.withLock {
            closed = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending.values { continuation.resume() }
    }

    func wait(timeout: Duration) async throws {
        try Task.checkCancellation()
        if isClosed { return }
        guard timeout > .zero else { throw TDError.timeout }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitForUpdate() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TDError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitForUpdate() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if closed { return .success(()) }
                    waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// Free-standing C-convention callback that routes TDLib internal log messages
/// into the unified os.Logger pipeline. Required to be a top-level function with
/// no captures so the Swift compiler can lower it to a plain C function pointer.
/// TDLib verbosity levels: 0 fatal, 1 error, 2 warning, 3 info, 4+ debug.
private func tdLogMessageCallback(verbosity: Int32, message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let raw = String(cString: message)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    switch verbosity {
    case 0, 1:
        Logger.tdlib.error("[v\(verbosity, privacy: .public)] \(trimmed, privacy: .public)")
    case 2:
        Logger.tdlib.warning("[v\(verbosity, privacy: .public)] \(trimmed, privacy: .public)")
    case 3:
        Logger.tdlib.info("[v\(verbosity, privacy: .public)] \(trimmed, privacy: .public)")
    default:
        Logger.tdlib.debug("[v\(verbosity, privacy: .public)] \(trimmed, privacy: .public)")
    }
}

/// Low-level Swift wrapper around TDLib's tdjson C API.
/// Handles JSON serialization/deserialization and request-response matching.
final class TDJsonWrapper: @unchecked Sendable {
    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], any Error>
        var timeoutTask: Task<Void, Never>?
    }

    /// td_receive must not run on two threads at once, and several wrappers
    /// can coexist while a client restarts. Its result lives in a thread-local
    /// buffer (ClientJson.cpp current_output) copied before the lock is
    /// released; td_execute uses its caller's own buffer and needs no lock.
    private static let tdReceiveLock = NSLock()

    // td_receive is process-wide: another wrapper can consume this client's
    // terminal update. Share only the native completion, before ID filtering.
    private static let closeStatesLock = NSLock()
    private nonisolated(unsafe) static var closeStates: [Int32: TDCompletionBarrier] = [:]
    private let registersNativeClient: Bool
    /// What `send(_:)` waits for an answer before it throws `TDError.timeout`.
    private let requestTimeoutNanos: UInt64

    /// Lazy one-shot installer for the global TDLib log message callback.
    /// `td_set_log_message_callback` is process-wide (not per client), so
    /// installing it on first TDJsonWrapper allocation is sufficient. Swift's
    /// `static let` is thread-safe and fires exactly once.
    private static let logCallbackInstalled: Void = {
        td_set_log_message_callback(Int32(AppLogSettings.tdlibVerbosity), tdLogMessageCallback)
    }()

    let clientId: Int32
    private var nextExtra: Int64 = 1
    private let lock = NSLock()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var isClosed = false
    private var closeRequested = false
    private let nativeClose = TDCompletionBarrier()
    private let sendJSON: @Sendable (Int32, String) -> Void
    private let receiveJSON: @Sendable (Double) -> String?
    private let executeJSON: @Sendable (String) -> String?

    /// Optional Phase 1 diagnostic sink. Set by TDLibService once after
    /// construction and before the first send. Nil when telemetry is disabled.
    var telemetry: TDRequestTelemetry?

    private var updateHandler: (@Sendable ([String: Any]) -> Void)?
    /// td_receive blocks for up to a second, so the loop owns a thread: on the
    /// watch the Swift concurrency pool has only two.
    private var receiveThread: Thread?
    private var receiveDrain: TDCompletionBarrier?
    private let receiveTaskLock = NSLock()
    private let updateQueue = DispatchQueue(label: "com.orbitext.td-updates", qos: .utility)

    // MARK: - Pause/Resume

    /// Guards `_isPaused` and `receiveStopRequested`; the paused receive
    /// thread waits on it without using CPU.
    private let pauseCondition = NSCondition()
    private var _isPaused = false
    private var receiveStopRequested = false

    var isPaused: Bool {
        pauseCondition.withLock { _isPaused }
    }

    func pause() {
        // Once closing begins, a late background callback must not suspend
        // the only receiver capable of observing native terminal closure.
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        pauseCondition.withLock { _isPaused = true }
        if AppLogSettings.verboseTDTransport {
            Logger.network.debug("TDJsonWrapper: receive loop PAUSED")
        }
    }

    func resume() {
        pauseCondition.withLock {
            _isPaused = false
            pauseCondition.broadcast()
        }
        if AppLogSettings.verboseTDTransport {
            Logger.network.debug("TDJsonWrapper: receive loop RESUMED")
        }
    }

    /// Blocks the receive thread while paused. False once the loop must stop.
    private func waitWhilePaused() -> Bool {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        while _isPaused && !receiveStopRequested {
            pauseCondition.wait()
        }
        return !receiveStopRequested
    }

    private var isReceiveStopRequested: Bool {
        pauseCondition.withLock { receiveStopRequested }
    }

    private func requestReceiveStop() {
        pauseCondition.withLock {
            receiveStopRequested = true
            pauseCondition.broadcast()
        }
    }

    init() {
        _ = Self.logCallbackInstalled // ensure global log callback is registered
        // Every call into TDLib but td_receive goes through one long-lived
        // thread: TDLib leaks the per-thread buffers of a pool thread that exits.
        let calls = TDNativeCallThread.shared
        clientId = calls.sync { td_create_client_id() }
        registersNativeClient = true
        requestTimeoutNanos = AppConstants.Network.requestTimeoutNanos
        sendJSON = { clientId, json in calls.async { td_send(clientId, json) } }
        receiveJSON = { Self.receiveJSON(timeout: $0) }
        executeJSON = { json in calls.sync { Self.executeJSON(json) } }
        Self.closeStatesLock.withLock { Self.closeStates[clientId] = nativeClose }
    }

    /// Inject the transport boundary so terminal-close behavior can be tested offline.
    init(
        clientId: Int32,
        send: @escaping @Sendable (Int32, String) -> Void,
        receive: @escaping @Sendable (Double) -> String?,
        execute: @escaping @Sendable (String) -> String? = { _ in nil },
        requestTimeoutNanos: UInt64 = AppConstants.Network.requestTimeoutNanos
    ) {
        self.clientId = clientId
        registersNativeClient = false
        self.requestTimeoutNanos = requestTimeoutNanos
        sendJSON = send
        receiveJSON = receive
        executeJSON = execute
    }

    var isNativeClosed: Bool { nativeClose.isClosed }

    var pendingRequestCountForTesting: Int {
        lock.withLock { pendingRequests.count }
    }

    deinit {
        stop()
        if registersNativeClient {
            _ = Self.closeStatesLock.withLock { Self.closeStates.removeValue(forKey: clientId) }
        }
    }

    /// Start the receive loop that processes TDLib responses/updates.
    func startReceiveLoop(onUpdate: @escaping @Sendable ([String: Any]) -> Void) {
        receiveTaskLock.lock()
        defer { receiveTaskLock.unlock() }
        guard receiveThread == nil, !nativeClose.isClosed else { return }
        updateHandler = onUpdate
        pauseCondition.withLock { receiveStopRequested = false }

        // Update processing runs on a GCD serial queue (not cooperative pool)
        // to avoid exhausting the 2-thread cooperative pool on Apple Watch.
        let handler = onUpdate
        let queue = updateQueue
        let drain = TDCompletionBarrier()

        let thread = Thread { [weak self] in
            defer {
                // The sentinel runs after every callback queued by this receiver.
                queue.async { drain.complete() }
            }
            while true {
                // A paused loop waits on the condition until resume() (0% CPU),
                // outside any autorelease pool. Closing may finish meanwhile.
                guard let self, self.waitWhilePaused(), !self.nativeClose.isClosed else { return }

                // Block for the first event to avoid idle polling, then drain
                // anything already queued without blocking so bursts remain fast.
                // This thread lives as long as the client: without a pool per
                // event, every parsed update stays autoreleased until it exits.
                var responseJSON = autoreleasepool { self.receiveJSON(1.0) }
                while let json = responseJSON {
                    guard autoreleasepool(invoking: { self.dispatchReceived(json, onUpdate: handler) }) else { return }
                    responseJSON = autoreleasepool { self.receiveJSON(0) }
                }
            }
        }
        thread.name = "com.orbitext.td-receive"
        thread.qualityOfService = .userInitiated
        receiveThread = thread
        receiveDrain = drain
        thread.start()
    }

    /// Parses one td_receive result and queues it for handling. False once the
    /// receiver must stop.
    private func dispatchReceived(_ json: String, onUpdate handler: @escaping @Sendable ([String: Any]) -> Void) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }

        if registersNativeClient { Self.observeNativeClose(obj) }
        guard !isReceiveStopRequested else { return false }

        // Skip events from old/dead TDLib clients -
        // td_receive() returns events for ALL clients globally
        if let eventClientId = obj["@client_id"] as? Int32, eventClientId != clientId {
            return true
        }

        nonisolated(unsafe) let incoming = obj
        updateQueue.async {
            self.handleIncomingObject(incoming, onUpdate: handler)
        }
        return true
    }

    private static func observeNativeClose(_ update: [String: Any]) {
        guard update["@type"] as? String == "updateAuthorizationState",
              let state = update["authorization_state"] as? [String: Any],
              state["@type"] as? String == "authorizationStateClosed",
              let clientId = update["@client_id"] as? Int32 else { return }
        let barrier = closeStatesLock.withLock { closeStates[clientId] }
        barrier?.complete()
    }

    private static func receiveJSON(timeout: Double) -> String? {
        serializedReceive(timeout: timeout) { td_receive($0) }
    }

    /// The locking half of `receiveJSON`, with the native call injectable so
    /// tests can observe overlapping receives and reuse of the result buffer.
    static func serializedReceive(timeout: Double, nativeReceive: (Double) -> UnsafePointer<CChar>?) -> String? {
        tdReceiveLock.lock()
        defer { tdReceiveLock.unlock() }
        guard let responsePtr = nativeReceive(timeout) else { return nil }
        return String(cString: responsePtr)
    }

    private func handleIncomingObject(_ obj: [String: Any], onUpdate handler: @escaping ([String: Any]) -> Void) {
        if obj["@type"] as? String == "updateAuthorizationState",
           let state = obj["authorization_state"] as? [String: Any],
           state["@type"] as? String == "authorizationStateClosed" {
            nativeClose.complete()
            finishPendingRequests()
        }
        if let extra = obj["@extra"] as? String {
            let pendingCount = lock.withLock { pendingRequests.count }
            let pending = removePendingRequest(extra: extra)

            if let type = obj["@type"] as? String, type == "error" {
                let code = obj["code"] as? Int ?? 0
                let message = obj["message"] as? String ?? "Unknown error"
                Logger.network.error("td_receive[\(extra)] error: \(code) \(message) (pending: \(pendingCount))")
                pending?.continuation.resume(throwing: TDError.api(code: code, message: message))
            } else {
                let responseType = obj["@type"] as? String ?? "unknown"
                if AppLogSettings.verboseTDTransport {
                    Logger.network.debug("td_receive[\(extra)] \(responseType) (pending: \(pendingCount))")
                }
                nonisolated(unsafe) let result = obj
                pending?.continuation.resume(returning: result)
            }
            if pending == nil {
                let responseType = obj["@type"] as? String ?? "unknown"
                Logger.network.warning("td_receive[\(extra)] \(responseType) - orphaned")
            }
        } else {
            handler(obj)
        }
    }

    /// Send a request and wait for the response (30s timeout, unless injected).
    func send(_ request: sending [String: Any]) async throws -> sending [String: Any] {
        try await send(request, timeoutNanos: requestTimeoutNanos)
    }

    /// Send a request with a custom timeout in nanoseconds.
    func send(_ request: sending [String: Any], timeoutNanos: UInt64) async throws -> sending [String: Any] {
        try await send(request, timeoutNanos: Optional(timeoutNanos))
    }

    /// Send a request and wait indefinitely for the response.
    func sendWithoutTimeout(_ request: sending [String: Any]) async throws -> sending [String: Any] {
        try await send(request, timeoutNanos: nil)
    }

    private func send(_ request: sending [String: Any], timeoutNanos: UInt64?) async throws -> sending [String: Any] {
        let requestType = request["@type"] as? String ?? "unknown"
        let extra: String = try lock.withLock {
            if isClosed {
                throw TDError.clientClosed
            }
            let e = "\(nextExtra)"
            nextExtra += 1
            return e
        }

        var req = request
        req["@extra"] = extra

        if let telemetry, AppLogSettings.tdTelemetryEnabled {
            let extraNum = UInt64(extra) ?? 0
            let burst = await telemetry.record(
                method: requestType,
                extraId: extraNum,
                captureStack: AppLogSettings.tdTelemetryStack
            )
            if burst {
                Logger.network.warning("td_burst: \(requestType, privacy: .public) reached burst threshold")
            }
        }

        let timeoutDesc = timeoutNanos.map { "\($0 / 1_000_000_000)s" } ?? "none"
        let pendingCount = lock.withLock { pendingRequests.count }
        if AppLogSettings.verboseTDTransport {
            Logger.network.debug("td_send[\(extra, privacy: .public)] \(requestType, privacy: .public) timeout=\(timeoutDesc, privacy: .public) pending=\(pendingCount)")
        }

        nonisolated(unsafe) let safeReq = req
        guard let data = try? JSONSerialization.data(withJSONObject: safeReq),
              let jsonString = String(data: data, encoding: .utf8) else {
            throw TDError.serializationFailed
        }

        let dict: [String: Any] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = timeoutNanos.map { timeoutNanos in
                    Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: timeoutNanos)
                        } catch {
                            return
                        }
                        Logger.network.warning("td_timeout[\(extra, privacy: .public)] \(requestType, privacy: .public) after \(timeoutDesc, privacy: .public)")
                        self?.finishPendingRequest(extra: extra, throwing: TDError.timeout)
                    }
                }

                let closed = self.lock.withLock { () -> Bool in
                    if self.isClosed {
                        return true
                    }
                    self.pendingRequests[extra] = PendingRequest(
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                    return false
                }
                if closed {
                    timeoutTask?.cancel()
                    continuation.resume(throwing: TDError.clientClosed)
                    return
                }

                if Task.isCancelled {
                    self.finishPendingRequest(extra: extra, throwing: CancellationError())
                    return
                }

                self.sendJSON(self.clientId, jsonString)
            }
        } onCancel: {
            self.finishPendingRequest(extra: extra, throwing: CancellationError())
        }
        let response = TDResponse(dict: dict)
        let responseType = response.dict["@type"] as? String ?? "unknown"
        if AppLogSettings.verboseTDTransport {
            Logger.network.debug("td_recv[\(extra, privacy: .public)] \(requestType, privacy: .public) → \(responseType, privacy: .public)")
        }
        return response.dict
    }

    /// Execute a synchronous TDLib request.
    func execute(_ request: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: data, encoding: .utf8),
              let result = executeJSON(jsonString),
              let resultData = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else { return nil }
        return obj
    }

    /// No lock: the result is in this thread's own buffer, so td_execute
    /// never waits for a receive that blocks up to a second.
    private static func executeJSON(_ request: String) -> String? {
        guard let resultPtr = td_execute(request) else { return nil }
        return String(cString: resultPtr)
    }

    /// Begin native teardown without blocking. Keep a live receiver running
    /// until the terminal update so a later stopAndWait can confirm closure.
    /// Safe to call from any context, including `deinit`.
    /// Callers that need to remove TDLib's database files afterwards
    /// MUST successfully await `stopAndWait()` before deletion.
    func stop() {
        requestNativeClose()
        resume()
    }

    /// Wait for authorizationStateClosed, then drain the Swift receive loop.
    /// A timeout or cancellation leaves the receiver alive so a retained client
    /// can finish closing and a caller can retry. Neither permits DB deletion.
    func stopAndWait(timeout: Duration = .seconds(10)) async throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + timeout
        if !nativeClose.isClosed {
            requestNativeClose()
            let handler = receiveTaskLock.withLock { updateHandler } ?? { _ in }
            startReceiveLoop(onUpdate: handler)
            resume()
            try await nativeClose.wait(timeout: deadline - .now)
        }
        try Task.checkCancellation()
        requestReceiveStop()
        let drain = receiveTaskLock.withLock { receiveDrain }
        // One deadline covers the native event, receiver exit, and callbacks.
        // Keep this shared barrier and thread handle on timeout so retry cannot
        // skip callbacks that still belong to the old client.
        try await drain?.wait(timeout: deadline - .now)
        try Task.checkCancellation()
        receiveTaskLock.withLock {
            receiveThread = nil
            receiveDrain = nil
        }
        finishPendingRequests()
    }

    private func requestNativeClose() {
        let shouldSend = lock.withLock {
            guard !closeRequested else { return false }
            closeRequested = true
            isClosed = true
            return true
        }
        guard shouldSend, !nativeClose.isClosed else { return }
        sendJSON(clientId, "{\"@type\":\"close\"}")
        finishPendingRequests()
    }

    private func finishPendingRequests() {
        // A paused receiver must wake to observe the terminal update.
        resume()

        let pending = lock.withLock {
            isClosed = true
            let p = pendingRequests
            pendingRequests.removeAll()
            return p
        }

        for (_, pendingRequest) in pending {
            pendingRequest.timeoutTask?.cancel()
            // Already handed to TDLib: it may have acted on it.
            pendingRequest.continuation.resume(throwing: TDError.requestAbandoned)
        }
    }

    private func removePendingRequest(extra: String) -> PendingRequest? {
        let pending = lock.withLock { pendingRequests.removeValue(forKey: extra) }
        pending?.timeoutTask?.cancel()
        return pending
    }

    private func finishPendingRequest(extra: String, throwing error: any Error) {
        guard let pending = removePendingRequest(extra: extra) else { return }
        pending.continuation.resume(throwing: error)
    }
}

enum TDError: LocalizedError {
    case api(code: Int, message: String)
    case serializationFailed
    case clientClosed
    case requestAbandoned
    case unexpectedResponse
    case timeout
    case phoneNumberInvalid
    case chatNotFound
    case unauthorized
    case rateLimited(seconds: Int)

    enum Category {
        case auth, network, data, transient
    }

    var category: Category {
        switch self {
        case .phoneNumberInvalid, .unauthorized: return .auth
        case .chatNotFound, .unexpectedResponse, .serializationFailed: return .data
        case .timeout, .clientClosed, .requestAbandoned: return .network
        case .rateLimited: return .transient
        case .api(let code, let message):
            if floodWaitSeconds != nil { return .transient }
            if code == 401 || message == "SESSION_REVOKED" || message == "AUTH_KEY_UNREGISTERED" { return .auth }
            if message == "PHONE_NUMBER_INVALID" { return .auth }
            if message == "Chat not found" { return .data }
            return .network
        }
    }

    var errorDescription: String? {
        switch self {
        case .api(_, let message): return message
        case .serializationFailed: return "Failed to serialize request"
        case .clientClosed: return "TDLib client closed"
        case .requestAbandoned: return "TDLib closed before answering"
        case .unexpectedResponse: return "Unexpected response from TDLib"
        case .timeout: return "Request timed out"
        case .phoneNumberInvalid: return "Invalid phone number"
        case .chatNotFound: return "Chat not found"
        case .unauthorized: return "Authentication required"
        case .rateLimited(let seconds): return "Please wait \(seconds)s"
        }
    }

    var isFloodWait: Bool { floodWaitSeconds != nil }

    var isSessionRevoked: Bool {
        if case .api(_, let message) = self {
            return message == "SESSION_REVOKED" || message == "AUTH_KEY_UNREGISTERED"
        }
        if case .unauthorized = self { return true }
        return false
    }

    var floodWaitSeconds: Int? {
        switch self {
        case .api(let code, let message):
            let suffix: Substring
            if message.hasPrefix("FLOOD_WAIT_") {
                suffix = message.dropFirst("FLOOD_WAIT_".count)
            } else if code == 429, message.hasPrefix("Too Many Requests: retry after ") {
                suffix = message.dropFirst("Too Many Requests: retry after ".count)
            } else {
                return nil
            }
            guard !suffix.isEmpty, suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let seconds = Int(suffix), seconds > 0 else { return nil }
            return seconds
        case .rateLimited(let seconds):
            return seconds > 0 ? seconds : nil
        default:
            return nil
        }
    }
}
