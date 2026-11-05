import Foundation

enum AuthState: Equatable {
    case idle
    case waitPhoneNumber
    case waitOtherDeviceConfirmation
    case waitCode
    case waitPassword(hint: String)
    case ready
    case closing
    case error(String)
}
