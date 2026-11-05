import Foundation
import os
import Synchronization
#if os(watchOS)
import WatchKit
#endif

/// A closed or logged-out client the transport has to recover from, as the
/// auth handler decided. The service runs it under its lifecycle gate.
struct AuthRecovery: Sendable {
    let client: TDJsonWrapper
    let reason: String
    var delaySeconds: UInt64 = 0
    /// Wipe the session instead of restarting on the same database.
    var forceLogout = false
}

/// What setTdlibParameters tells TDLib about the app and its database.
struct TDLibParameters: Sendable {
    let databaseDirectory: URL
    /// TDLib's `bytes` JSON type is base64-encoded. An empty key opens or
    /// creates an unencrypted DB; a 32-byte key enables AES-256 encryption.
    /// The key was resolved in start() by TDLibDatabaseKey.resolveAtStart
    /// and staged in the coordinator.
    let encryptionKey: Data
    let apiId: Int
    let apiHash: String

    /// Built where it is sent: a JSON dictionary is not Sendable, its parts are.
    var request: [String: Any] {
        [
            "@type": "setTdlibParameters",
            "database_directory": databaseDirectory.path,
            "files_directory": databaseDirectory.appendingPathComponent("files").path,
            "database_encryption_key": encryptionKey.base64EncodedString(),
            "use_file_database": true,
            // Enable chat info database: telemetry showed ~1700 hydration
            // queries (0xefd9a6a2) + ~1200 (0x2c4ada50) firing after a
            // single getChats, because TDLib had to refetch every chat's
            // metadata from the server on cold start. Persisting it to
            // SQLite cuts the post-login MTProto storm by ~80% on
            // subsequent launches.
            "use_chat_info_database": true,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": Locale.current.language.languageCode?.identifier ?? "en",
            "device_model": TDRuntime.deviceModel,
            "system_version": TDRuntime.systemVersion,
            "application_version": AppConstants.App.version
        ]
    }
}

/// The authorization state machine of the transport: what each TDLib
/// authorization state means for the app, the TDLib parameters and their
/// database key, the QR login link, and the restarts after a client closed
/// on its own.
///
/// Every authorization state, whether an update or the answer to the
/// bootstrap request, is handled on one serial queue, in arrival order. The
/// queue is entered with no lock held. The queue orders handlers among
/// themselves, not against the transitions that retire a client and start
/// the next, so a handler checks its client again for every effect it has
/// on the transport's state and on the app: the check, the effect and the
/// emit share the session lock (`whileCurrent`). A state of a client that
/// was retired in the meantime changes nothing and is not reported.
final class AuthCoordinator: Sendable {
    static let maxRestarts = AppConstants.App.maxRestarts

    private struct State {
        var didSubmitTdlibParameters = false
        var isLoggingOut = false
        var ignoreNextAuthorizationClosed = false
        var observed: AuthState = .idle
        var deduper = AuthEventDeduper()
        var restartCount = 0
        var qrRefreshTask: Task<Void, Never>?
        /// The database key staged for setTdlibParameters.
        var databaseKey = Data()
        var needsDatabaseKeyMigration = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.orbitext.td-auth", qos: .userInitiated)
    private let afterClientCheck = Mutex<(@Sendable () -> Void)?>(nil)
    private let session: TDClientSession
    private let push: PushRegistrar
    private let presence: PresenceController
    private let apiId: Int
    private let apiHash: String
    private let databaseDirectory: URL

    init(
        session: TDClientSession,
        push: PushRegistrar,
        presence: PresenceController,
        apiId: Int,
        apiHash: String,
        databaseDirectory: URL
    ) {
        self.session = session
        self.push = push
        self.presence = presence
        self.apiId = apiId
        self.apiHash = apiHash
        self.databaseDirectory = databaseDirectory
    }

    // MARK: - Reporting

    /// The state the app was last told.
    var observedState: AuthState {
        get { state.withLock { $0.observed } }
        set { state.withLock { $0.observed = newValue } }
    }

    /// Restarts since the last ready or wiped session. Internal for tests.
    var restartCount: Int {
        state.withLock { $0.restartCount }
    }

    /// Emitted under the auth lock, so the stream and `observedState` agree
    /// on the order of states.
    func emitAuthState(_ authState: AuthState) {
        state.withLock { state in
            guard state.deduper.shouldEmitAuthState(authState) else { return }
            state.observed = authState
            session.emit(.authStateChanged(authState))
        }
    }

    /// For work that reports on the client it started with: once another
    /// client is current, its outcome is no longer news. The check and the
    /// emit share the session lock, so a swap cannot slip between them.
    func emitAuthState(_ authState: AuthState, ifCurrent client: TDJsonWrapper) {
        session.ifCurrent(client) { emitAuthState(authState) }
    }

    @discardableResult
    func emitQRCodeLink(_ link: String) -> Bool {
        state.withLock { state in
            guard state.deduper.shouldEmitQRCodeLink(link) else { return false }
            session.emit(.qrCodeLink(link))
            return true
        }
    }

    /// Polls for a state the app is waiting for, such as the phone number
    /// prompt before a phone number can be sent. An error state ends the wait.
    func waitForState(
        _ predicate: @escaping (AuthState) -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            let observed = observedState
            if predicate(observed) {
                return
            }
            if case .error(let message) = observed {
                throw TDError.api(code: 0, message: message)
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw TDError.timeout
    }

    // MARK: - Lifecycle

    /// A new client starts from scratch: parameters unsent, nothing reported.
    func prepareForNewClient() {
        state.withLock { state in
            state.didSubmitTdlibParameters = false
            state.ignoreNextAuthorizationClosed = false
            state.observed = .idle
            state.deduper.reset()
        }
    }

    /// A client about to be bootstrapped again reports from idle.
    func resetObservedState() {
        observedState = .idle
    }

    /// The transport closes the client itself: its closed state is ours to
    /// handle, not a spontaneous close to recover from.
    func expectOwnClose() {
        state.withLock { $0.ignoreNextAuthorizationClosed = true }
    }

    func beginUserLogout() {
        state.withLock { $0.isLoggingOut = true }
    }

    func cancelUserLogout() {
        state.withLock { $0.isLoggingOut = false }
    }

    /// The session was wiped: the next sign-in starts at the phone number.
    /// The caller reports it once the rest of the transport is reset.
    func sessionWiped() {
        stopQRCodeRefreshPolling()
        state.withLock { state in
            state.isLoggingOut = false
            state.didSubmitTdlibParameters = false
            state.ignoreNextAuthorizationClosed = true
            state.observed = .waitPhoneNumber
            state.deduper.reset()
            state.restartCount = 0
        }
    }

    // MARK: - Database key

    /// The key setTdlibParameters opens the database with, resolved before
    /// the client is created.
    func stageDatabaseKey(_ key: Data, needsMigration: Bool) {
        state.withLock { state in
            state.databaseKey = key
            state.needsDatabaseKeyMigration = needsMigration
        }
    }

    /// The key belonged to a database that is gone.
    func clearDatabaseKey() {
        stageDatabaseKey(Data(), needsMigration: false)
    }

    /// Internal for tests.
    var stagedDatabaseKey: Data {
        get { state.withLock { $0.databaseKey } }
        set { state.withLock { $0.databaseKey = newValue } }
    }

    // MARK: - Handling authorization states

    /// Handles one authorization state of `client` (nil: of no particular
    /// client) and returns the recovery it calls for, if any. Waits for
    /// states that arrived before it.
    func handle(_ authorizationState: [String: Any], from client: TDJsonWrapper?) -> AuthRecovery? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { process(authorizationState, from: client) }
    }

    private func process(_ authorizationState: [String: Any], from sourceClient: TDJsonWrapper?) -> AuthRecovery? {
        // A state of a client that is already retired is dropped here. The
        // check is repeated under the session lock for what a state does.
        if let sourceClient, !session.isCurrent(sourceClient) { return nil }
        afterClientCheck.withLock { $0 }?()
        guard let type = authorizationState["@type"] as? String else { return nil }

        switch type {
        case "authorizationStateWaitTdlibParameters":
            submitParameters(to: sourceClient)

        case "authorizationStateWaitPhoneNumber":
            whileCurrent(sourceClient) {
                stopQRCodeRefreshPolling()
                push.invalidate(clearRegistered: true)
                presence.forgetAppliedStatus(wantingOnline: true)
                emitAuthState(.waitPhoneNumber)
            }

        case "authorizationStateWaitCode":
            whileCurrent(sourceClient) {
                stopQRCodeRefreshPolling()
                emitAuthState(.waitCode)
            }

        case "authorizationStateWaitPassword":
            let hint = authorizationState["password_hint"] as? String ?? ""
            whileCurrent(sourceClient) {
                stopQRCodeRefreshPolling()
                emitAuthState(.waitPassword(hint: hint))
            }

        case "authorizationStateReady":
            // Read before the step: the session lock is held inside it.
            let readyClient = sourceClient ?? session.client
            whileCurrent(sourceClient) {
                stopQRCodeRefreshPolling()
                state.withLock { $0.restartCount = 0 }
                push.markReady()
                if let readyClient { finishSignIn(on: readyClient) }
                emitAuthState(.ready)
            }

        case "authorizationStateClosing":
            whileCurrent(sourceClient) {
                stopQRCodeRefreshPolling()
                push.invalidate()
                presence.forgetAppliedStatus(wantingOnline: false)
                emitAuthState(.closing)
            }

        case "authorizationStateLoggingOut":
            return handleLoggingOut(of: sourceClient)

        case "authorizationStateClosed":
            return handleClosed(of: sourceClient)

        case "authorizationStateWaitOtherDeviceConfirmation":
            whileCurrent(sourceClient) {
                emitAuthState(.waitOtherDeviceConfirmation)
                if let link = authorizationState["link"] as? String {
                    if emitQRCodeLink(link) {
                        Logger.auth.info("QR login link received")
                    }
                } else {
                    Logger.auth.error("QR state received but no link present")
                }
                startQRCodeRefreshPolling()
            }

        default:
            break
        }
        return nil
    }

    /// Runs `effect` only while `client` is current (always when a state
    /// names no client), under the session lock, so no install or retirement
    /// can fall between the check and the effect. Nil when `client` is not
    /// current. `effect` takes the lock of one component at a time and must
    /// not call into the session.
    @discardableResult
    private func whileCurrent<T: Sendable>(_ client: TDJsonWrapper?, _ effect: () -> T) -> T? {
        guard let client else { return effect() }
        return session.ifCurrent(client, effect)
    }

    private func submitParameters(to sourceClient: TDJsonWrapper?) {
        // Pin the client now: a task that reads the current one when it
        // finally runs could send a second setTdlibParameters to a
        // replacement client, which TDLib rejects.
        guard let td = sourceClient ?? session.client else { return }
        // Decided while the client is current: a flag set for a client that
        // was retired since would make the next client's request look like a
        // duplicate, and it would never get its parameters.
        let stagedKey: Data? = whileCurrent(sourceClient) {
            state.withLock { state -> Data? in
                guard !state.didSubmitTdlibParameters else { return nil }
                state.didSubmitTdlibParameters = true
                return state.databaseKey
            }
        } ?? nil
        guard let stagedKey else {
            if AppLogSettings.verboseTDInternals {
                Logger.tdlib.debug("Ignoring duplicate authorizationStateWaitTdlibParameters")
            }
            return
        }

        let parameters = TDLibParameters(
            databaseDirectory: databaseDirectory,
            encryptionKey: stagedKey,
            apiId: apiId,
            apiHash: apiHash
        )
        Task { [weak self] in
            guard let self else { return }
            // Send setTdlibParameters, then immediately queue setOption calls.
            // TDLib processes its internal queue sequentially:
            //   1. setTdlibParameters -> opens DB, finds auth key
            //   2. setOption(ignore_background_updates) -> applied before getDifference
            //   3. setOption(...) -> applied before getDifference
            //   4. TDLib transitions to authReady -> getDifference starts WITH options
            //
            // We must NOT await setTdlibParameters before sending options,
            // otherwise getDifference starts before options are queued.
            Logger.tdlib.info("Sending setTdlibParameters + optimization options in batch")

            // Fire setTdlibParameters (will await response below).
            // The Task's synchronous prefix calls td_send before the first
            // await, so setTdlibParameters is queued in TDLib first.
            let paramsTask = Task { _ = try await td.sendWithoutTimeout(parameters.request) }

            // Immediately queue optimization options via the tracked wrapper
            // so responses (or errors) are observable. Each Task's
            // synchronous prefix calls td_send, preserving send order
            // params -> option1 -> option2 -> option3 inside TDLib's queue.
            // Storage + network-stats hygiene: on watchOS the FS is tight
            // and network-stats are never surfaced, so we keep TDLib's
            // storage optimizer on and skip both the in-memory and
            // persistent network statistics counters.
            for option in [
                "disable_top_chats",
                "ignore_background_updates",
                "ignore_inline_thumbnails",
                "use_storage_optimizer",
                "disable_network_statistics",
                "disable_persistent_network_statistics"
            ] {
                Task {
                    do {
                        _ = try await td.send([
                            "@type": "setOption",
                            "name": option,
                            "value": ["@type": "optionValueBoolean", "value": true] as [String: Any]
                        ])
                        if AppLogSettings.verboseTDTransport {
                            Logger.network.debug("setOption(\(option, privacy: .public)) ok")
                        }
                    } catch {
                        Logger.tdlib.warning("setOption(\(option, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            // Now await setTdlibParameters response
            do {
                try await paramsTask.value
                Logger.tdlib.info("setTdlibParameters completed")
            } catch TDError.requestAbandoned, TDError.clientClosed {
                // This client is closing (logout, restart, reset). Whoever
                // closed it reports the outcome; an init error would flash
                // over the sign-in screen that follows.
                Logger.tdlib.info("setTdlibParameters cut off: the client is closing")
            } catch {
                Logger.tdlib.error("setTdlibParameters failed: \(error.localizedDescription)")
                self.emitAuthState(.error("TDLib init failed: \(error.localizedDescription)"), ifCurrent: td)
            }
        }
    }

    /// After authorizationStateReady: re-key a legacy database, learn the
    /// account id, and register the push token. For the client that became
    /// ready, not for whichever is current when the work runs.
    private func finishSignIn(on td: TDJsonWrapper) {
        Task { [weak self] in
            guard let self else { return }
            // Migration: if we opened a legacy unencrypted DB
            // with an empty key, re-key it now. The new key is generated
            // and stored in Keychain BEFORE the setDatabaseEncryptionKey
            // call so a crash mid-migration leaves the key recoverable.
            let needsMigration = self.state.withLock { $0.needsDatabaseKeyMigration }
            if needsMigration {
                await self.migrateDatabaseEncryptionKey(td: td)
            }
            do {
                if AppLogSettings.verboseTDTransport {
                    Logger.network.debug("-> getMe (direct send, no throttle)")
                }
                let me = try await td.send(["@type": "getMe"])
                guard self.session.setAccountUserID(TDApi.int64(me["id"]), reportedBy: td) else { return }
                if AppLogSettings.verboseTDTransport {
                    Logger.network.debug("<- getMe ok, userId=\(self.session.accountUserID)")
                }
            } catch {
                Logger.tdlib.error("getMe failed: \(error.localizedDescription, privacy: .public)")
            }
            await self.push.registerPendingIfNeeded()
        }
    }

    private func handleLoggingOut(of sourceClient: TDJsonWrapper?) -> AuthRecovery? {
        // Read before the step: the session lock is held inside it.
        let isTransitionInProgress = session.isTransitionInProgress
        let oldTD = sourceClient ?? session.client
        let isUserLogout = state.withLock { $0.isLoggingOut }
        let wasCurrent = whileCurrent(sourceClient) { () -> Bool in
            stopQRCodeRefreshPolling()
            push.invalidate()
            presence.forgetAppliedStatus(wantingOnline: false)
            emitAuthState(.closing)
            return true
        } ?? false
        guard wasCurrent else { return nil }
        Logger.auth.info("LoggingOut detected (userInitiated=\(isUserLogout))")

        guard !isUserLogout, !isTransitionInProgress else { return nil }
        Logger.auth.warning("Stale loggingOut detected - awaiting native closure before cleanup")
        guard let oldTD else { return nil }
        return AuthRecovery(client: oldTD, reason: "stale loggingOut", forceLogout: true)
    }

    private func handleClosed(of sourceClient: TDJsonWrapper?) -> AuthRecovery? {
        // The wrapper records the terminal event before this callback. An
        // explicit logout/start transition owns any cleanup it unlocks.
        guard !session.isTransitionInProgress else { return nil }
        // Keep the client retained until the async barrier succeeds. Read
        // before the step: the session lock is held inside it.
        let oldTD = sourceClient ?? session.client
        return whileCurrent(sourceClient) { recoveryAfterClose(of: oldTD) } ?? nil
    }

    private func recoveryAfterClose(of oldTD: TDJsonWrapper?) -> AuthRecovery? {
        let (shouldIgnoreClosed, restartAfterLogout) = state.withLock { state -> (Bool, Bool) in
            if state.ignoreNextAuthorizationClosed {
                state.ignoreNextAuthorizationClosed = false
                state.isLoggingOut = false
                state.didSubmitTdlibParameters = false
                return (true, false)
            }
            let shouldRestartImmediately = state.isLoggingOut
            state.isLoggingOut = false
            state.didSubmitTdlibParameters = false
            return (false, shouldRestartImmediately)
        }
        if shouldIgnoreClosed {
            if AppLogSettings.verboseTDInternals {
                Logger.tdlib.debug("Ignoring late authorizationStateClosed after local logout cleanup")
            }
            return nil
        }
        push.invalidate(clearRegistered: true)
        presence.forgetAppliedStatus(wantingOnline: true)
        guard let oldTD else { return nil }

        if restartAfterLogout {
            state.withLock { $0.restartCount = 0 }
            Logger.tdlib.info("Logout completed, restarting client for fresh login...")
            return AuthRecovery(client: oldTD, reason: "post-logout restart")
        }

        let restartCount = state.withLock { state -> Int in
            state.restartCount += 1
            return state.restartCount
        }
        if restartCount <= Self.maxRestarts {
            let delay = UInt64(pow(2.0, Double(restartCount)))
            Logger.tdlib.info("Restarting client (attempt \(restartCount)/\(Self.maxRestarts)) in \(delay)s...")
            return AuthRecovery(client: oldTD, reason: "restart attempt \(restartCount)", delaySeconds: max(delay, 2))
        }
        Logger.tdlib.error("Max restarts reached - forcing clean restart")
        return AuthRecovery(client: oldTD, reason: "max-restarts fallback", forceLogout: true)
    }

    // MARK: - QR login

    /// Auth states arrive on the auth queue and wipes come from lifecycle
    /// transitions, so the task handle is only read and written under the
    /// auth lock.
    func startQRCodeRefreshPolling() {
        state.withLock { state in
            if let task = state.qrRefreshTask, !task.isCancelled { return }
            state.qrRefreshTask = makeQRCodeRefreshTask()
        }
    }

    func stopQRCodeRefreshPolling() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.qrRefreshTask
            state.qrRefreshTask = nil
            return task
        }
        task?.cancel()
    }

    private func makeQRCodeRefreshTask() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // Telegram documents QR login tokens as expiring in usually
                // 30 seconds. Polling at half that interval keeps the QR link
                // fresh without repeatedly scheduling QR matrix generation.
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self.observedState == .waitOtherDeviceConfirmation, let td = self.session.client else { return }

                do {
                    let authState = try await td.send(
                        ["@type": "getAuthorizationState"],
                        timeoutNanos: 10_000_000_000
                    )
                    self.applyQRRefreshResponse(authState, from: td)
                } catch is CancellationError {
                    return
                } catch {
                    Logger.auth.warning("QR auth state refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// A refresh only renews the QR link. State changes arrive as updates, and
    /// a response requested before a newer update would roll the state back:
    /// the QR screen came back for ~15 s right after the login completed.
    func applyQRRefreshResponse(_ response: [String: Any], from client: TDJsonWrapper) {
        guard session.isCurrent(client),
              response["@type"] as? String == "authorizationStateWaitOtherDeviceConfirmation",
              let link = response["link"] as? String,
              observedState == .waitOtherDeviceConfirmation else { return }
        if emitQRCodeLink(link) {
            Logger.auth.info("QR login link refreshed")
        }
    }

    // MARK: - Database encryption migration

    /// Re-key a legacy unencrypted TDLib database to a fresh 32-byte AES key,
    /// stored in the watchOS Keychain. Idempotent at the lock level: once
    /// needsDatabaseKeyMigration is cleared, subsequent ready events skip this.
    private func migrateDatabaseEncryptionKey(td: TDJsonWrapper) async {
        let newKey: Data
        do {
            newKey = try TDLibDatabaseKey.generate()
        } catch {
            Logger.tdlib.error("DB key migration: failed to generate new key: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Persist the key BEFORE issuing setDatabaseEncryptionKey so a crash
        // mid-operation leaves the key recoverable. TDLib treats the rekey as
        // atomic at the SQLite level; if it succeeds we keep using newKey, if
        // it fails the stored key matches what we passed (which is the same
        // value), so the next start either succeeds with newKey (TDLib was
        // re-keyed before crash) or falls back to migration again (legacy DB
        // intact).
        do {
            try TDLibDatabaseKey.store(newKey)
        } catch {
            Logger.tdlib.error("DB key migration: Keychain store failed, aborting: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            _ = try await td.send([
                "@type": "setDatabaseEncryptionKey",
                "new_encryption_key": newKey.base64EncodedString()
            ])
            stageDatabaseKey(newKey, needsMigration: false)
            Logger.tdlib.info("DB key migration: legacy DB re-keyed to encrypted")
        } catch {
            Logger.tdlib.error("DB key migration: setDatabaseEncryptionKey failed: \(error.localizedDescription, privacy: .public)")
            // Keychain still holds the new key, but TDLib didn't accept it.
            // Roll back so the next start does not try to use a key TDLib
            // does not know about.
            try? TDLibDatabaseKey.remove()
        }
    }

    // MARK: - Test seams

    /// Runs on the auth queue once the client of a state has been found
    /// current, before the state is acted on: where a handler is in flight.
    func setAfterClientCheckForTesting(_ hook: (@Sendable () -> Void)?) {
        afterClientCheck.withLock { $0 = hook }
    }
}

struct AuthEventDeduper {
    private var lastAuthState: AuthState = .idle
    private var lastQRCodeLink: String?

    mutating func shouldEmitAuthState(_ state: AuthState) -> Bool {
        guard lastAuthState != state else { return false }

        lastAuthState = state
        if state != .waitOtherDeviceConfirmation {
            lastQRCodeLink = nil
        }
        return true
    }

    mutating func shouldEmitQRCodeLink(_ link: String) -> Bool {
        guard lastQRCodeLink != link else { return false }

        lastQRCodeLink = link
        return true
    }

    mutating func reset() {
        lastAuthState = .idle
        lastQRCodeLink = nil
    }
}

/// How this device describes itself to TDLib and in the start log.
enum TDRuntime {
    static var environmentName: String {
#if targetEnvironment(simulator)
        "simulator"
#else
        "device"
#endif
    }

    static var deviceModel: String {
#if targetEnvironment(simulator)
        return "Apple Watch Simulator"
#elseif os(watchOS)
        let device = WKInterfaceDevice.current()
        let model = device.model.isEmpty ? device.localizedModel : device.model
        return model.isEmpty ? "Apple Watch" : model
#else
        return "Apple Watch"
#endif
    }

    static var systemVersion: String {
#if os(watchOS)
        let version = WKInterfaceDevice.current().systemVersion
        return version.isEmpty ? "watchOS" : "watchOS \(version)"
#else
        return ProcessInfo.processInfo.operatingSystemVersionString
#endif
    }
}
