import Foundation

/// The one place outside the transport that decides which transport the app
/// runs on, so no other app code needs to name the TDLib implementation.
enum TelegramServiceFactory {
    static func live() -> any TelegramServiceProtocol {
        TDLibService()
    }
}
