import Foundation
import Observation
import os

@MainActor
@Observable
final class AuthManager {
    var authState: AuthState = .idle
    var qrCodeLink: String?
    var isLoading = false
    var errorPresenter: ErrorPresenter?
    private var isRequestingQRCode = false
    private var lastQRCodeRequestAt: Date?

    private let service: TelegramServiceProtocol

    init(service: TelegramServiceProtocol, errorPresenter: ErrorPresenter? = nil) {
        self.service = service
        self.errorPresenter = errorPresenter
    }

    // MARK: - Auth Actions

    func requestQRCodeAuth(forceRefresh: Bool = false) async {
        if !forceRefresh {
            if qrCodeLink != nil || isRequestingQRCode {
                return
            }
            if let lastQRCodeRequestAt,
               Date().timeIntervalSince(lastQRCodeRequestAt) < 30 {
                return
            }
        }

        isRequestingQRCode = true
        defer { isRequestingQRCode = false }
        lastQRCodeRequestAt = Date()
        await performAuth { try await self.service.requestQRCodeAuthentication() }
    }

    func sendPhone(_ phone: String) async {
        guard authState == .waitPhoneNumber else {
            Logger.auth.warning("sendPhone ignored: auth state is \(String(describing: self.authState), privacy: .public)")
            return
        }
        qrCodeLink = nil
        await performAuth { try await self.service.setPhoneNumber(phone) }
    }

    /// Whether TDLib is currently in QR code auth flow (waitOtherDeviceConfirmation).
    /// Phone number submission is not allowed in this state.
    var isInQRFlow: Bool {
        authState == .waitOtherDeviceConfirmation || qrCodeLink != nil
    }

    func sendCode(_ code: String) async {
        await performAuth { try await self.service.setAuthCode(code) }
    }

    func sendPassword(_ password: String) async {
        await performAuth { try await self.service.setPassword(password) }
    }

    /// Stores the link TDLib reports, or drops it when the auth state moves
    /// on. The anti-spam window is left alone: this runs for every auth
    /// update, and the window exists to bound the requests the user triggers.
    func setQRCodeLink(_ link: String?) {
        qrCodeLink = link
        if link != nil {
            isRequestingQRCode = false
        }
    }

    /// The user left the QR flow (back, reset, logout): there is no link to
    /// protect any more, so entering the flow again may ask for one at once.
    func clearQRCodeLinkAndThrottle() {
        setQRCodeLink(nil)
        lastQRCodeRequestAt = nil
    }

    private func performAuth(_ action: () async throws -> Void) async {
        guard !isLoading else { return }
        isLoading = true
        errorPresenter?.dismiss()
        defer { isLoading = false }
        do {
            try await action()
        } catch is CancellationError {
            // User navigated away or scenePhase change cancelled the
            // in-flight Task - do NOT show an error toast or play the
            // failure haptic for a request we ourselves abandoned.
            // (Mirrors the same pattern in MessageManager.)
            return
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
        }
    }
}
