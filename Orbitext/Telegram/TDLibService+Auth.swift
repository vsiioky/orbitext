import Foundation
import os

// MARK: - Authorization states and sign-in requests

extension TDLibService {
    /// Hands an authorization state of `sourceClient` to the auth coordinator
    /// and runs the recovery it calls for, under the lifecycle gate.
    func handleAuthUpdate(_ state: [String: Any], sourceClient: TDJsonWrapper? = nil) {
        guard let recovery = auth.handle(state, from: sourceClient) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recoverClosedClient(
                    recovery.client,
                    reason: recovery.reason,
                    delaySeconds: recovery.delaySeconds,
                    forceLogout: recovery.forceLogout
                )
            } catch {
                self.auth.emitAuthState(.error(error.localizedDescription))
            }
        }
    }

    func setPhoneNumber(_ phone: String) async throws {
        let td = try await ensureAuthClientReady(for: "setPhoneNumber") { state in
            if case .waitPhoneNumber = state { return true }
            return false
        }
        _ = try await td.send([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": phone,
            "settings": [
                "@type": "phoneNumberAuthenticationSettings",
                "allow_flash_call": false,
                "allow_missed_call": false,
                "is_current_phone_number": false,
                "has_unknown_phone_number": false,
                "allow_sms_retriever_api": false
            ] as [String: Any]
        ])
    }

    func setAuthCode(_ code: String) async throws {
        let td = try await ensureAuthClientReady(for: "setAuthCode") { state in
            if case .waitCode = state { return true }
            return false
        }
        _ = try await td.send([
            "@type": "checkAuthenticationCode",
            "code": code
        ])
    }

    func setPassword(_ password: String) async throws {
        let td = try await ensureAuthClientReady(for: "setPassword") { state in
            if case .waitPassword = state { return true }
            return false
        }
        _ = try await td.send([
            "@type": "checkAuthenticationPassword",
            "password": password
        ])
    }

    func requestQRCodeAuthentication() async throws {
        let td = try await ensureAuthClientReady(for: "requestQRCodeAuthentication") { state in
            if case .waitPhoneNumber = state { return true }
            return false
        }
        Logger.auth.info("Requesting QR code authentication...")
        _ = try await td.send([
            "@type": "requestQrCodeAuthentication",
            "other_user_ids": [] as [Int]
        ])
        Logger.auth.debug("requestQrCodeAuthentication completed")
    }

    private func ensureAuthClientReady(
        for requestName: String,
        matching predicate: @escaping (AuthState) -> Bool
    ) async throws -> TDJsonWrapper {
        if getTD() == nil {
            Logger.auth.info("Bootstrapping TDLib for \(requestName, privacy: .public)")
            auth.resetObservedState()
            await start()
        }

        try await auth.waitForState(predicate)

        guard let td = getTD() else {
            throw ServiceError.notStarted
        }
        return td
    }
}
