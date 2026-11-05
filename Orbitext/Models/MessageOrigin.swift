import Foundation

/// Typed parse of TDLib's MessageOrigin variants used for
/// `forward_info.origin` (and one day for reply origin). Replaces the
/// previous String? collapse that lost the distinction between user /
/// hidden user / chat / channel forwards.
enum MessageOrigin: Equatable, Hashable, Codable, Sendable {
    case user(userId: Int64, name: String)
    case hiddenUser(name: String)
    case chat(chatId: Int64, title: String, authorSignature: String?)
    case channel(chatId: Int64, title: String, authorSignature: String?)

    var displayName: String {
        switch self {
        case .user(_, let name):
            return name
        case .hiddenUser(let name):
            return name
        case .chat(_, let title, let signature),
             .channel(_, let title, let signature):
            if let signature, !signature.isEmpty {
                return "\(title) (\(signature))"
            }
            return title
        }
    }

    var isChannel: Bool {
        if case .channel = self { return true }
        return false
    }
}
