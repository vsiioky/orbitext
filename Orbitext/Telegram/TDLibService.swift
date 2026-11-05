import Foundation
import os
import Synchronization

actor TDLocalConcurrencyLimiter {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

actor TDChatListLoadCoordinator {
    private var inFlight: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, any Error>]] = [:]

    func begin(key: String) async throws -> Bool {
        if !inFlight.contains(key) {
            inFlight.insert(key)
            return true
        }

        try await withCheckedThrowingContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
        return false
    }

    func finish(key: String, result: Result<Void, any Error>) {
        inFlight.remove(key)
        let pending = waiters.removeValue(forKey: key) ?? []
        for waiter in pending {
            waiter.resume(with: result)
        }
    }
}

/// Real TDLib implementation using the tdjson C API.
/// Requires TDLib static libraries linked to the project.
///
/// The service is the composition root of the transport and runs the client
/// lifecycle (start, logout, reset, recovery) under the session's lifecycle
/// gate. Its parts keep their own state:
/// - TDClientSession - the current client, its generation, transitions,
///   account id and the event stream
/// - TDRequestSender - throttled and local sends, FLOOD_WAIT
/// - AuthCoordinator - authorization states, TDLib parameters, QR login
/// - PushRegistrar - the APNs token registration and remote pushes
/// - PresenceController - the online status and the receive loop pause
///
/// The request APIs are facades over them, split across files:
/// - TDLibService+Auth.swift - sign-in requests, recoveries the auth states call for
/// - TDLibService+Updates.swift - TDLib update dispatch
/// - TDLibService+Chats.swift - chat list, folders, pin, mute, mark-as-read
/// - TDLibService+Messages.swift - message CRUD and search
/// - TDLibService+Reactions.swift - reactions and typing
/// - TDLibService+Files.swift - file download, contacts, group info, drafts
/// - TDLibService+Parsers.swift - chat/contact/reaction parsers, helpers
/// - TDLibService+NameResolver.swift - name resolution for forwards/replies
///
/// Lock order (read before nesting withLock):
///
/// Every part keeps its mutable state in one Mutex, and the service adds
/// only `chatActions`. The session lock is the one lock held while another
/// is taken, through TDClientSession.ifCurrent and withCurrentClient:
///
///     TDClientSession
///       -> AuthCoordinator | PushRegistrar | PresenceController
///        | TDRequestSender.floodWait
///
/// One of the four under the session lock at a time, never one inside
/// another. PresenceController also holds its lock while it pauses or
/// resumes the receive loop, which takes only TDJsonWrapper's leaf locks;
/// it reads the session before its lock, never under it. No other lock is
/// held while the session's or a part's lock is taken. AuthCoordinator's
/// queue is entered with no lock held. The caches and TDJsonWrapper keep
/// their own locks and call nothing back under them.
///
/// emit() takes no lock and may be called under any of them. Client
/// generation markers are yielded under the session lock, so swapping the
/// client, bumping the generation and the marker are one step for every
/// thread that emits.
final class TDLibService: TelegramServiceProtocol, Sendable {
    let session = TDClientSession()
    var events: AsyncStream<TDLibEvent> { session.events }
    /// Every chat TDLib announced in this session. TDLib sends each chat once
    /// (updateNewChat) and then only field updates, so an evicted chat would
    /// silently stop receiving them: this mirror must never drop entries.
    let chatCache = LRUThreadSafeCache<Int64, ChatInfo>(maxSize: nil)
    let userCache = LRUThreadSafeCache<Int64, UserInfo>(maxSize: AppConstants.Cache.userCacheSize)
    let replyMessageCache = LRUThreadSafeCache<MessageKey, TDApi.Message>(maxSize: 256)
    var myUserId: Int64 {
        get { session.accountUserID }
        set { session.accountUserID = newValue }
    }
    var currentUserID: Int64? {
        let id = myUserId
        return id == 0 ? nil : id
    }

    /// A delayed getMe result cannot restore identity after native shutdown.
    @discardableResult
    func cacheCurrentUserID(_ id: Int64, from client: TDJsonWrapper) -> Bool {
        session.setAccountUserID(id, reportedBy: client)
    }

    /// Bounded sender, action kind, and monotonic recency state for each chat.
    let chatActions = Mutex(ChatActionState())

    /// What a start leaves behind, written while holding session.lifecycleGate.
    private struct StartupState {
        var hasFailure = false
        var bootstrapTask: Task<Void, Never>?
        var telemetryDumpTask: Task<Void, Never>?
    }

    private let startup = Mutex(StartupState())

    let apiId: Int
    let apiHash: String
    /// Throttled and local sends, and the FLOOD_WAIT shown in Settings.
    let requests: TDRequestSender
    var throttle: TDRequestThrottle { requests.throttle }
    /// This device's APNs registration with the signed-in account.
    let push: PushRegistrar
    /// The account's online status, foreground or background.
    let presence: PresenceController
    /// What each authorization state means, the TDLib parameters and the
    /// restarts after a spontaneous close.
    let auth: AuthCoordinator
    /// Which copies of sent voice notes TDLib may still upload from.
    let voiceUploads: VoiceUploadLedger
    let chatListLoadCoordinator = TDChatListLoadCoordinator()
    let getChatCacheMissLimiter = TDLocalConcurrencyLimiter(maxConcurrent: 4)

    /// Phase 1 diagnostic telemetry. Records every outgoing TDLib send so the
    /// periodic dump task and the Settings "Export TDLib trace" button can
    /// answer "which method is being spammed and from where". Nil when
    /// AppLogSettings.tdTelemetryEnabled is false (Release builds by default).
    let telemetry: TDRequestTelemetry? = AppLogSettings.tdTelemetryEnabled
        ? TDRequestTelemetry(ringCapacity: 500, burstThreshold: 3, burstWindow: 5)
        : nil

    // MARK: - Database encryption

    //
    // The TDLib local database holds the entire message history and the
    // authenticated session key material. It is encrypted with a random 32-byte
    // key generated at first launch and stored in the watchOS Keychain
    // (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). Existing legacy
    // unencrypted installations are migrated on the first run after this code
    // ships: the DB is opened with an empty key and then re-keyed via
    // setDatabaseEncryptionKey after authorizationStateReady. The key is
    // staged in `auth`, which sends the parameters and migrates.
    let dbPath: URL
    private let removeDatabaseKey: @Sendable () throws -> Void
    private let nativeCloseTimeout: Duration
    private let logoutServerTimeout: Duration
    /// A download fails once nothing the transport downloads has gained bytes
    /// for this long, as the request timeout made every download fail before
    /// downloads could take longer.
    let downloadStallTimeout: Duration
    /// How often a running download is checked for progress.
    let downloadProgressInterval: Duration
    /// How long a download that answered "incomplete" waits before asking again.
    let downloadRetryDelay: Duration
    /// Which downloads of this transport gained bytes, so that one queued
    /// behind the others can tell waiting from stalling.
    let downloadProgress = DownloadProgressBeat()
    private let resolveDatabaseKey: @Sendable (URL) throws -> (key: Data, needsMigration: Bool)
    /// Creates the native client each start runs. Tests hand `start()` a
    /// scripted one, so the receive loop the app runs is the one under test.
    private let makeClient: @Sendable () -> TDJsonWrapper

    init(
        databaseDirectory: URL? = nil,
        nativeCloseTimeout: Duration = .seconds(10),
        logoutServerTimeout: Duration = .seconds(AppConstants.App.logoutServerTimeout),
        requestThrottle: TDRequestThrottle? = nil,
        downloadStallTimeout: Duration = .nanoseconds(Int64(AppConstants.Network.requestTimeoutNanos)),
        downloadProgressInterval: Duration = .seconds(5),
        downloadRetryDelay: Duration = .milliseconds(250),
        apiCredentials: (id: Int, hash: String)? = nil,
        resolveDatabaseKey: @escaping @Sendable (URL) throws -> (key: Data, needsMigration: Bool) = {
            try TDLibDatabaseKey.resolveAtStart(databaseDirectory: $0)
        },
        removeDatabaseKey: @escaping @Sendable () throws -> Void = { try TDLibDatabaseKey.remove() },
        makeClient: @escaping @Sendable () -> TDJsonWrapper = { TDJsonWrapper() }
    ) {
        dbPath = databaseDirectory ?? FileManager.appSupportDirectory.appendingPathComponent("tdlib", isDirectory: true)
        voiceUploads = VoiceUploadLedger(fileURL: dbPath
            .appendingPathComponent("voice-uploads", isDirectory: true)
            .appendingPathComponent("pending.json"))
        self.nativeCloseTimeout = nativeCloseTimeout
        self.logoutServerTimeout = logoutServerTimeout
        self.downloadStallTimeout = downloadStallTimeout
        self.downloadProgressInterval = downloadProgressInterval
        self.downloadRetryDelay = downloadRetryDelay
        requests = TDRequestSender(session: session, throttle: requestThrottle ?? TDRequestThrottle())
        push = PushRegistrar(session: session, requests: requests)
        presence = PresenceController(session: session, requests: requests)
        self.removeDatabaseKey = removeDatabaseKey
        self.resolveDatabaseKey = resolveDatabaseKey
        self.makeClient = makeClient

        let bundle = Bundle.main
        self.apiId = apiCredentials?.id ?? bundle.object(forInfoDictionaryKey: "TDLIB_API_ID") as? Int
            ?? Int(bundle.object(forInfoDictionaryKey: "TDLIB_API_ID") as? String ?? "") ?? 0
        self.apiHash = apiCredentials?.hash ?? bundle.object(forInfoDictionaryKey: "TDLIB_API_HASH") as? String ?? ""
        auth = AuthCoordinator(
            session: session,
            push: push,
            presence: presence,
            apiId: apiId,
            apiHash: apiHash,
            databaseDirectory: dbPath
        )
        ensureDatabaseDirectoriesExist()
    }

    func emit(_ event: TDLibEvent) {
        session.emit(event)
    }

    var filesPath: URL {
        dbPath.appendingPathComponent("files", isDirectory: true)
    }

    // MARK: - Lifecycle

    func getTD() -> TDJsonWrapper? {
        session.client
    }

    var clientGeneration: TDClientGeneration {
        session.generation
    }

    /// Makes `client` current and starts its generation and chat list session.
    /// Internal for tests.
    func installClient(_ client: TDJsonWrapper) {
        session.install(client)
    }

    func isCurrentTDClient(_ client: TDJsonWrapper) -> Bool {
        session.isCurrent(client)
    }

    func handleUpdate(_ update: [String: Any], from client: TDJsonWrapper) {
        guard isCurrentTDClient(client) else { return }
        if update["@type"] as? String == "updateAuthorizationState",
           let state = update["authorization_state"] as? [String: Any] {
            handleAuthUpdate(state, sourceClient: client)
        } else {
            handleUpdate(update)
        }
    }

    var isClientTransitionInProgress: Bool {
        session.isTransitionInProgress
    }

    private func beginClientTransition() async throws -> TDClientLifecycleGate.Lease {
        try await session.beginTransition()
    }

    private func endClientTransition(_ lease: TDClientLifecycleGate.Lease) {
        session.endTransition(lease)
    }

    /// Keep ownership until native shutdown is confirmed, including on failures.
    private func closeCurrentClient() async throws {
        push.invalidate()
        if let oldTD = getTD() {
            auth.expectOwnClose()
            try await oldTD.stopAndWait(timeout: nativeCloseTimeout)
        }
        try Task.checkCancellation()
    }

    /// Used by spontaneous terminal auth updates before a fresh client starts.
    func finishClosedClient(_ client: TDJsonWrapper?, reason: String) async throws {
        let lease = try await beginClientTransition()
        defer { endClientTransition(lease) }
        guard session.client === client else { throw TDError.clientClosed }
        try await closeCurrentClient()
        try removeAndRecreateDatabaseDirectory(reason: reason)
        session.retire()
    }

    /// Returns remaining FLOOD_WAIT seconds, or nil if no active flood wait.
    func currentFloodWaitRemaining() -> Int? {
        requests.currentFloodWaitRemaining()
    }

    /// An unthrottled read of TDLib's local database (see TDRequestSender).
    func localSend(_ request: sending [String: Any]) async throws -> [String: Any] {
        try await requests.localSend(request)
    }

    /// An unthrottled local request without a timeout (see TDRequestSender).
    func localSendWithoutTimeout(_ request: sending [String: Any]) async throws -> [String: Any] {
        try await requests.localSendWithoutTimeout(request)
    }

    /// A local read that shares an identical one in flight.
    func dedupedLocalSend(_ request: [String: Any], key: String) async throws -> [String: Any] {
        try await requests.dedupedLocalSend(request, key: key)
    }

    func cachedOrFetchChat(chatId: Int64) async throws -> ChatInfo {
        if let cached = chatCache.get(chatId) {
            return cached
        }
        let result = try await dedupedLocalSend(
            ["@type": "getChat", "chat_id": chatId],
            key: "getChat:\(chatId)"
        )
        // TDLib announces a chat before it returns it, and the mirror follows
        // every update in order. A chat the mirror holds by now was announced
        // while the request ran, so the mirror has the state the answer had
        // and what changed after it: a mute or a position that arrived in the
        // meantime is newer than the answer, which can also lack positions.
        // Only a chat nothing announced takes the answer.
        if let current = chatCache.get(chatId) {
            return current
        }
        let info = parseChatInfo(result)
        chatCache.set(chatId, info)
        return info
    }

    func boundedCachedOrFetchChat(chatId: Int64) async throws -> ChatInfo {
        await getChatCacheMissLimiter.acquire()
        do {
            let info = try await cachedOrFetchChat(chatId: chatId)
            await getChatCacheMissLimiter.release()
            return info
        } catch {
            await getChatCacheMissLimiter.release()
            throw error
        }
    }

    func coalescedLoadChats(chatList: ChatListID, limit: Int, reason: String) async throws {
        let key = chatListLoadKey(chatList: chatList.tdRequest, limit: limit)
        let shouldLoad = try await chatListLoadCoordinator.begin(key: key)
        guard shouldLoad else { return }

        do {
            Logger.network.info(
                "loadChats requested reason=\(reason, privacy: .public) limit=\(limit) key=\(key, privacy: .public)"
            )
            _ = try await self.throttledSend([
                "@type": "loadChats",
                "chat_list": chatList.tdRequest,
                "limit": limit
            ])
            await chatListLoadCoordinator.finish(key: key, result: .success(()))
        } catch {
            await chatListLoadCoordinator.finish(key: key, result: .failure(error))
            throw error
        }
    }

    private func chatListLoadKey(chatList: [String: Any], limit: Int) -> String {
        let type = chatList["@type"] as? String ?? "unknown"
        let folderId = toInt64(chatList["chat_folder_id"])
        return "\(type):\(folderId):\(limit)"
    }

    func cachedOrFetchUser(userId: Int64) async throws -> UserInfo {
        if let cached = userCache.get(userId) {
            return cached
        }
        let result = try await dedupedLocalSend(
            ["@type": "getUser", "user_id": userId],
            key: "getUser:\(userId)"
        )
        let user = UserInfo(tdApi: TDApi.decodeUser(result))
        userCache.set(userId, user)
        return user
    }

    /// A request that may reach Telegram, after a throttle slot.
    func throttledSend(_ request: sending [String: Any]) async throws -> [String: Any] {
        try await requests.throttledSend(request)
    }

    /// A throttled request without a timeout; `prepare` edits it right before
    /// it is sent.
    func throttledSendWithoutTimeout(
        _ request: sending [String: Any],
        prepare: @escaping @Sendable (inout [String: Any]) -> Void
    ) async throws -> [String: Any] {
        try await requests.throttledSendWithoutTimeout(request, prepare: prepare)
    }

    func start() async {
        guard let lease = try? await beginClientTransition() else { return }
        defer { endClientTransition(lease) }
        await startWhileHoldingLifecycleGate()
    }

    /// Retrying a failed bootstrap preserves the existing DB and credentials.
    /// The source check and restart share a lease, so callers cannot race cleanup.
    func retryStartupIfNeeded() async throws -> Bool {
        let lease = try await beginClientTransition()
        defer { endClientTransition(lease) }
        guard startup.withLock({ $0.hasFailure }) else { return false }
        auth.emitAuthState(.idle)
        await startWhileHoldingLifecycleGate()
        return true
    }

    private func startWhileHoldingLifecycleGate() async {
        guard apiId != 0, !apiHash.isEmpty else {
            startup.withLock { $0.hasFailure = true }
            auth.emitAuthState(.error("Missing API credentials. Copy Orbitext.xcconfig.example to Orbitext.local.xcconfig and set TDLIB_API_ID and TDLIB_API_HASH."))
            return
        }

        do {
            try await closeCurrentClient()
        } catch {
            startup.withLock { $0.hasFailure = true }
            Logger.tdlib.error("Cannot restart before native client closure: \(error.localizedDescription, privacy: .public)")
            auth.emitAuthState(.error(error.localizedDescription))
            return
        }
        session.retire()

        ensureDatabaseDirectoriesExist()
        // Nothing else deletes a copy if no voice note follows it.
        removeVoiceUploads(olderThan: Self.voiceUploadRetention)
        removeLegacyVoiceUploads()

        // Resolve database encryption key BEFORE creating the TDJsonWrapper so
        // setTdlibParameters (sent from the auth-state handler) can use it.
        let resolvedKey: Data
        let needsMigration: Bool
        do {
            (resolvedKey, needsMigration) = try resolveDatabaseKey(dbPath)
        } catch {
            startup.withLock { $0.hasFailure = true }
            Logger.tdlib.error("TDLib DB key: failed to provision encryption key: \(error.localizedDescription, privacy: .public)")
            auth.emitAuthState(.error(error.localizedDescription))
            return
        }
        auth.stageDatabaseKey(resolvedKey, needsMigration: needsMigration)

        Logger.tdlib.info(
            "TDLib start env=\(TDRuntime.environmentName, privacy: .public) bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) api_id=\(self.apiId, privacy: .private) push_sandbox=\(PushRegistrar.isSandboxEnvironment) device_model=\(TDRuntime.deviceModel, privacy: .public) system_version=\(TDRuntime.systemVersion, privacy: .public) db=\(self.dbPath.path, privacy: .public)"
        )

        let leftover = startup.withLock { startup in
            defer {
                startup.bootstrapTask = nil
                startup.telemetryDumpTask = nil
            }
            return (startup.bootstrapTask, startup.telemetryDumpTask)
        }
        leftover.0?.cancel()
        leftover.1?.cancel()

        let client = makeClient()
        client.telemetry = telemetry
        installClient(client)
        startup.withLock { $0.hasFailure = false }
        await throttle.resetSpacing()
        auth.prepareForNewClient()
        presence.forgetAppliedStatus(wantingOnline: true)
        chatActions.withLock { $0.reset() }

        _ = client.execute([
            "@type": "setLogVerbosityLevel",
            "new_verbosity_level": AppLogSettings.tdlibVerbosity
        ])

        if AppLogSettings.tdTelemetryPeriodicDump, let telemetry {
            let dump = Task.detached(priority: .utility) { [weak telemetry, weak client] in
                var iter = 0
                while !Task.isCancelled {
                    let delayNs: UInt64 = iter == 0 ? 3_000_000_000 : 10_000_000_000
                    try? await Task.sleep(nanoseconds: delayNs)
                    if Task.isCancelled { return }
                    guard let telemetry, let client else { return }
                    iter += 1
                    guard !client.isPaused, let report = await telemetry.periodicDump() else { continue }
                    Logger.network.notice("TDTelemetry dump:\n\(report, privacy: .public)")
                }
            }
            startup.withLock { $0.telemetryDumpTask = dump }
        }

        client.startReceiveLoop { [weak self, weak client] update in
            guard let client else { return }
            let type = update["@type"] as? String ?? "unknown"
            let quiet: Set = ["updateOption", "updateChatPosition", "updateUserStatus", "updateChatAction",
                               "updateUser", "updateSupergroup", "updateBasicGroup",
                               "updateUserFullInfo", "updateSupergroupFullInfo", "updateBasicGroupFullInfo",
                               "updateChatAvailableReactions", "updateChatActiveStories",
                               "updateChatNotificationSettings", "updateChatReadOutbox", "updateChatReadInbox",
                               "updateChatAddedToList", "updateFile",
                               "updateNewChat", "updateChatLastMessage", "updateUnreadChatCount",
                               "updateUnreadMessageCount", "updateDeleteMessages",
                               "updateMessageInteractionInfo", "updateChatUnreadReactionCount",
                               "updateHavePendingNotifications", "updateConnectionState",
                               "updateSavedMessagesTopic", "updateChatActionBar"]
            if AppLogSettings.verboseTDInternals, !quiet.contains(type) {
                Logger.tdlib.debug("update: \(type)")
            }
            self?.handleUpdate(update, from: client)
        }

        let bootstrap = Task { [weak self, client] in
            guard let self else { return }
            do {
                let state = try await client.sendWithoutTimeout([
                    "@type": "getAuthorizationState"
                ])
                guard !Task.isCancelled, self.isCurrentTDClient(client) else { return }
                Logger.tdlib.info("getAuthorizationState completed")
                self.handleAuthUpdate(state, sourceClient: client)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentTDClient(client) else { return }
                Logger.tdlib.error("getAuthorizationState failed: \(error.localizedDescription)")
                self.auth.emitAuthState(.error("TDLib auth bootstrap failed: \(error.localizedDescription)"), ifCurrent: client)
            }
        }
        startup.withLock { $0.bootstrapTask = bootstrap }
    }

    // MARK: - Background Lifecycle

    func suspendForBackground() {
        presence.goOffline()
    }

    func resumeFromBackground() {
        presence.goOnline()
    }

    func updatePushDeviceToken(_ token: Data) async {
        await push.updateDeviceToken(token)
    }

    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool {
        try await push.handleRemotePush(payload: payload)
    }

    /// Ends the session on the server, then wipes it locally. Waiting for the
    /// server without a bound hung logout for minutes offline or under
    /// FLOOD_WAIT (ea347af), so after `logoutServerTimeout` the local wipe
    /// runs regardless and an unconfirmed server session is left to expire.
    func logout() async throws {
        let lease = try await beginClientTransition()
        defer { endClientTransition(lease) }
        auth.beginUserLogout()
        // A registration worker still waiting for a throttle slot would send
        // the real token after our empty one and re-enable pushes.
        push.invalidate(clearRegistered: true)
        if let td = getTD() {
            await signOutOnServer(using: td)
        }
        do {
            try await cleanupClosedSession()
        } catch {
            auth.cancelUserLogout()
            throw error
        }
    }

    /// Best effort: stop pushes to this device, then log the session out.
    /// Each request gets half of `logoutServerTimeout`, measured from its own
    /// send, so a slow unregister or a suspended process never skips logOut,
    /// which ends the session itself. A failure is logged, not thrown.
    private func signOutOnServer(using td: TDJsonWrapper) async {
        let stepTimeout = (logoutServerTimeout / 2).wholeNanoseconds
        await signOutStep(push.unregisterRequest, using: td, timeoutNanos: stepTimeout)
        await signOutStep(["@type": "logOut"], using: td, timeoutNanos: stepTimeout)
    }

    private func signOutStep(_ request: sending [String: Any], using td: TDJsonWrapper, timeoutNanos: UInt64) async {
        let requestType = request["@type"] as? String ?? "unknown"
        do {
            _ = try await td.send(request, timeoutNanos: timeoutNanos)
            Logger.auth.info("Logout: \(requestType, privacy: .public) accepted")
        } catch {
            Logger.auth.warning(
                "Logout: \(requestType, privacy: .public) failed, wiping locally anyway: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func resetLocalSession() async throws {
        Logger.tdlib.warning("Resetting the local session without contacting the server")
        try await completeLocalLogoutCleanup()
    }

    func completeLocalLogoutCleanup() async throws {
        let lease = try await beginClientTransition()
        defer { endClientTransition(lease) }
        try await cleanupClosedSession()
    }

    private func cleanupClosedSession() async throws {
        // The session is being wiped, as in logout: its token must not count
        // as registered any more, even when the close below has to be retried.
        push.invalidate(clearRegistered: true)
        // Do not change app-visible session state, DB files, or the key until
        // the native terminal event has been observed. Failure is retryable.
        try await closeCurrentClient()
        try removeAndRecreateDatabaseDirectory(reason: "logout cleanup")
        await throttle.reset()
        startup.withLock { $0.hasFailure = false }
        // A FLOOD_WAIT is recorded only under the session lock while its
        // client is current, so none of the retired client's lands after this.
        session.retire()
        requests.forgetFloodWait()
        auth.sessionWiped()
        push.forgetRegistration()
        presence.forgetAppliedStatus(wantingOnline: true)
        auth.emitAuthState(.waitPhoneNumber)
        Logger.tdlib.info("Local logout cleanup completed; TDLib will restart on next auth request")
    }

    /// Backoff does not block user lifecycle requests. After waiting, recheck
    /// the source while holding the same lease used for cleanup and restart.
    func recoverClosedClient(
        _ client: TDJsonWrapper,
        reason: String,
        delaySeconds: UInt64 = 0,
        forceLogout: Bool = false
    ) async throws {
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }
        let lease = try await beginClientTransition()
        defer { endClientTransition(lease) }
        guard isCurrentTDClient(client) else { return }
        if forceLogout {
            try await cleanupClosedSession()
            return
        }
        try await closeCurrentClient()
        try removeAndRecreateDatabaseDirectory(reason: reason)
        session.retire()
        try Task.checkCancellation()
        await startWhileHoldingLifecycleGate()
    }

    /// Only the exclusive client transition may remove native storage.
    private func removeAndRecreateDatabaseDirectory(reason: String) throws {
        try Task.checkCancellation()
        guard isClientTransitionInProgress,
              getTD().map(\.isNativeClosed) ?? true else {
            throw ServiceError.nativeClientStillOpen
        }
        if FileManager.default.fileExists(atPath: dbPath.path) {
            try FileManager.default.removeItem(at: dbPath)
        }
        removeLegacyVoiceUploads()
        voiceUploads.reset()
        ensureDatabaseDirectoriesExist()
        // The DB key in Keychain is bound to the now-deleted DB; remove it so
        // the next start() generates a fresh key.
        try removeDatabaseKey()
        auth.clearDatabaseKey()
        chatCache.clear()
        userCache.clear()
        replyMessageCache.clear()
        myUserId = 0
        chatActions.withLock { $0.reset() }
    }

    func ensureDatabaseDirectoriesExist() {
        do {
            try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: filesPath, withIntermediateDirectories: true)
        } catch {
            Logger.tdlib.error("Failed to ensure TDLib DB dirs: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Folder Title Parsing

    func parseFolderTitle(_ info: [String: Any]) -> String {
        let clean = normalizeContent(info)

        // Structure: name -> chatFolderName { text -> formattedText { text: String } }
        // So path is: info["name"]["text"]["text"]
        for key in ["title", "name"] {
            guard let value = clean[key] else { continue }
            // Plain string (old TDLib)
            if let plain = value as? String, !plain.isEmpty {
                return plain
            }
            if let dict = value as? [String: Any] {
                // formattedText: { "text": "..." }
                if let text = dict["text"] as? String, !text.isEmpty {
                    return text
                }
                // chatFolderName: { "text": { "text": "..." } }
                if let inner = dict["text"] as? [String: Any], let text = inner["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return "Folder \(toInt64(clean["id"]))"
    }

    // MARK: - Errors

    typealias ServiceError = TelegramServiceError
}

private extension Duration {
    /// For `TDJsonWrapper.send(_:timeoutNanos:)`; negative durations become 0.
    var wholeNanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0 else { return 0 }
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}
