import Foundation

/// The decisions AuthFlowView makes from the auth state, without the view:
/// which input screen belongs to a state and when the back button shows.
enum AuthFlowLogic {
    /// The input screen for `waitPhoneNumber`. With no method picked yet but
    /// a QR link already present, the QR screen: the user is looking at a
    /// code the service asked for, and an explicit pick of another method
    /// always wins over it.
    static func effectiveMethod(method: AuthMethod, hasQRCodeLink: Bool) -> AuthMethod {
        if method == .none, hasQRCodeLink { return .qr }
        return method
    }

    /// The back button shows on every auth screen except the initial method
    /// picker and the states with an affordance of their own (progress, the
    /// error screen's Retry).
    static func shouldShowBackButton(authState: AuthState, method: AuthMethod, hasQRCodeLink: Bool) -> Bool {
        switch authState {
        case .waitPhoneNumber:
            return effectiveMethod(method: method, hasQRCodeLink: hasQRCodeLink) != .none
        case .waitOtherDeviceConfirmation, .waitCode, .waitPassword:
            return true
        case .idle, .ready, .closing, .error:
            return false
        }
    }
}
