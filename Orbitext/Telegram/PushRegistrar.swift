import Foundation
import os
import Synchronization

/// Registers this device's APNs token with TDLib for the signed-in account
/// and tells the account's remote pushes from other accounts'.
///
/// One registration worker serializes all pending token changes. Awaiting
/// callers share it, and cancelling one caller does not cancel another's
/// registration. Every close or replacement of the client invalidates the
/// worker first, so a late answer cannot restore an old registration.
final class PushRegistrar: Sendable {
    struct State {
        /// The client is authorized; registration waits for it.
        var isReady = false
        var pendingToken: String?
        var registeredToken: String?
        var receiverId: Int64?
        var registrationID: UUID?
        var registrationTask: Task<Void, Never>?
    }

    /// Internal for tests.
    let state = Mutex(State())
    private let session: TDClientSession
    private let requests: TDRequestSender

    init(session: TDClientSession, requests: TDRequestSender) {
        self.session = session
        self.requests = requests
    }

    func updateDeviceToken(_ token: Data) async {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        guard !tokenString.isEmpty else { return }

        let shouldRegister = state.withLock { state -> Bool in
            if state.pendingToken == tokenString,
               state.registeredToken == tokenString,
               state.receiverId != nil {
                return false
            }
            state.pendingToken = tokenString
            if state.registeredToken != tokenString {
                state.receiverId = nil
            }
            return true
        }
        guard shouldRegister else { return }
        await registerPendingIfNeeded()
    }

    /// The client reached authorizationStateReady: a token may register now.
    func markReady() {
        state.withLock { $0.isReady = true }
    }

    /// One service-owned worker serializes all pending token changes. Awaiting
    /// callers share it; canceling one caller does not cancel another's registration.
    func registerPendingIfNeeded() async {
        let task: Task<Void, Never>? = session.withCurrentClient { td in
            guard let client = td else { return nil }
            return state.withLock { state -> Task<Void, Never>? in
                guard state.isReady, let token = state.pendingToken, !token.isEmpty,
                      state.registeredToken != token || state.receiverId == nil else { return nil }
                if let task = state.registrationTask { return task }
                let id = UUID()
                state.registrationID = id
                let task = Task { [weak self, weak client] in
                    guard let self, let client else { return }
                    await self.runRegistration(id: id, client: client)
                }
                state.registrationTask = task
                return task
            }
        }
        await task?.value
    }

    /// Invalidates old callbacks before closing/replacing a native client.
    func invalidate(clearRegistered: Bool = false) {
        let task = state.withLock { state in
            state.isReady = false
            state.registrationID = nil
            let task = state.registrationTask
            state.registrationTask = nil
            if clearRegistered {
                state.receiverId = nil
                state.registeredToken = nil
            }
            return task
        }
        task?.cancel()
    }

    /// After a wipe: nothing about this device's registration with the wiped
    /// account survives. The APNs token does: it belongs to the device, not
    /// to the account, and the system hands it over once per process, so the
    /// next account to sign in on this device registers it.
    func forgetRegistration() {
        let task = state.withLock { state in
            let task = state.registrationTask
            state = State(pendingToken: state.pendingToken)
            return task
        }
        task?.cancel()
    }

    /// An empty Apple push token unregisters this device from the account.
    var unregisterRequest: [String: Any] {
        [
            "@type": "registerDevice",
            "device_token": [
                "@type": "deviceTokenApplePush",
                "device_token": "",
                "is_app_sandbox": Self.isSandboxEnvironment
            ] as [String: Any],
            "other_user_ids": [] as [Int64]
        ]
    }

    func handleRemotePush(payload remotePush: RemotePushPayload) async throws -> Bool {
        let payload = remotePush.json
        let expectedPushReceiverId = state.withLock { $0.receiverId }
        if let expectedPushReceiverId,
           let actualPushReceiverId = receiverId(for: payload),
           actualPushReceiverId != expectedPushReceiverId {
            if AppLogSettings.verboseTDInternals {
                Logger.tdlib.debug(
                    "Ignoring remote push for receiver=\(actualPushReceiverId) expected=\(expectedPushReceiverId)"
                )
            }
            return false
        }

        do {
            _ = try await requests.throttledSend([
                "@type": "processPushNotification",
                "payload": payload
            ])
            return true
        } catch let error as TDError {
            if case .api(let code, let message) = error, code == 406 {
                Logger.tdlib.info("processPushNotification requires sync: \(message, privacy: .public)")
                return true
            }
            throw error
        }
    }

    private func runRegistration(id: UUID, client: TDJsonWrapper) async {
        defer {
            state.withLock { state in
                if state.registrationID == id {
                    state.registrationID = nil
                    state.registrationTask = nil
                }
            }
        }
        while !Task.isCancelled, session.isCurrent(client) {
            let token: String? = state.withLock { state in
                guard state.registrationID == id else { return nil }
                guard state.isReady, let token = state.pendingToken, !token.isEmpty,
                      state.registeredToken != token || state.receiverId == nil else {
                    // Clear ownership atomically with checking the latest token.
                    state.registrationID = nil
                    state.registrationTask = nil
                    return nil
                }
                return token
            }
            guard let token else { return }
            do {
                // Background registration has nobody waiting: sit out the whole limit.
                let result = try await requests.throttledSend([
                    "@type": "registerDevice",
                    "device_token": [
                        "@type": "deviceTokenApplePush",
                        "device_token": token,
                        "is_app_sandbox": Self.isSandboxEnvironment
                    ] as [String: Any],
                    "other_user_ids": [] as [Int64]
                ], using: client, waitsForFullLimit: true, beforeSend: { [self] in
                    guard state.withLock({
                        $0.registrationID == id && $0.isReady && $0.pendingToken == token
                    }) else { throw CancellationError() }
                })
                guard result["@type"] as? String == "pushReceiverId", let rawId = result["id"] else {
                    throw TDError.unexpectedResponse
                }
                let receiverId = TDApi.int64(rawId)
                guard receiverId != 0 else { throw TDError.unexpectedResponse }
                guard !Task.isCancelled, session.isCurrent(client) else { return }
                let applied = state.withLock { state in
                    guard state.registrationID == id, state.isReady,
                          state.pendingToken == token else { return false }
                    state.receiverId = receiverId
                    state.registeredToken = token
                    return true
                }
                if applied { Logger.tdlib.info("Push receiver accepted by TDLib") }
            } catch is CancellationError {
                // A newer token may have replaced this attempt while it waited
                // for its slot. Recheck it; lifecycle cancellation exits the loop.
                if Task.isCancelled { return }
            } catch {
                guard !Task.isCancelled, session.isCurrent(client) else { return }
                Logger.tdlib.error("registerDevice failed: \(error.localizedDescription, privacy: .public)")
                if (error as? TDError)?.floodWaitSeconds != nil {
                    // The throttle owns the full server deadline. Retry without
                    // creating another registration worker or shortening the wait.
                    continue
                }
                let retryNewToken = state.withLock { state in
                    guard state.registrationID == id else { return false }
                    if state.pendingToken != token { return true }
                    state.registrationID = nil
                    state.registrationTask = nil
                    return false
                }
                if !retryNewToken { return }
            }
        }
    }

    private func receiverId(for payload: String) -> Int64? {
        guard let td = session.client,
              let result = td.execute([
                  "@type": "getPushReceiverId",
                  "payload": payload
              ]),
              result["@type"] as? String != "error" else {
            return nil
        }
        return TDApi.int64(result["id"])
    }

    static var isSandboxEnvironment: Bool {
        // Allow xcconfig override to force the production APNs cert path
        // from Debug builds. Useful when the sandbox cert is rejected by
        // APNs/Telegram and we want to confirm prod cert works.
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TDLIB_FORCE_PUSH_PRODUCTION") as? String ?? "").uppercased()
        if ["1", "YES", "TRUE"].contains(raw) {
            return false
        }
#if DEBUG
        return true
#else
        return false
#endif
    }
}
