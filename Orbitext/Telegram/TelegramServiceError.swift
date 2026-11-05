import Foundation

/// Failures every transport reports the same way, so app code can match them
/// without naming the TDLib implementation.
enum TelegramServiceError: LocalizedError {
    /// The transport has no running client yet: nothing reached the server.
    case notStarted
    case invalidFileId
    case downloadFailed
    case nativeClientStillOpen
    /// This transport does not offer the operation; callers fall back.
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notStarted: return "TDLib not started"
        case .invalidFileId: return "Invalid file ID"
        case .downloadFailed: return "File download failed"
        case .nativeClientStillOpen: return "TDLib database is still in use"
        case .unsupported: return "Not supported by this transport"
        }
    }
}
