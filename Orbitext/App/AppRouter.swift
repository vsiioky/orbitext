import Observation
import SwiftUI

enum AppDestination: Hashable {
    case chat(Int64)
    case compose(ComposeTarget)
    case attachments(chatId: Int64)
    case stickerPicker(chatId: Int64)
    case locationShare(chatId: Int64)
    case search
    case searchResult(chat: ChatInfo, messageId: Int64)
    /// A chat resolved outside the chat list (e.g. a t.me link from a bot
    /// button). Carries its ChatInfo because ChatView's chat-list lookup
    /// would otherwise fall back to a placeholder title.
    case resolvedChat(ChatInfo)
    case voiceRecorder(chatId: Int64)
    case profile(ChatInfo)
    case contacts
    case contactDetail(ContactInfo)
    case settings
    case mediaViewer(fileId: String)
}

/// Central navigation router. Owns the root NavigationStack path so push
/// notifications, widget deep-links, and URL schemes can drive navigation
/// from outside the view hierarchy.
///
/// Storage is `[AppDestination]` (not NavigationPath) so the path is
/// inspectable for tests and could be made Codable for SceneStorage if a
/// future scenePhase pipeline needs persistence. Preserving the
/// active chat across background/foreground lives in
/// ChatMessageStore.activeChatId and is independent of router state -
/// AppState is @State of OrbitextApp so router survives scene transitions.
@MainActor
@Observable
final class AppRouter {
    var path: [AppDestination] = [] {
        didSet {
            // A binding that writes the path it already has is not a change.
            if path != oldValue { onPathChanged?() }
        }
    }

    /// Called after every change to the path, from wherever it comes: a
    /// push, the user going back, or a deep link replacing the stack. The
    /// chat sessions follow the route through it.
    @ObservationIgnored var onPathChanged: (@MainActor () -> Void)?

    func push(_ destination: AppDestination) {
        path.append(destination)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path.removeAll()
    }

    func replace(with newPath: [AppDestination]) {
        path = newPath
    }

    /// The chat a route shows, for the routes that show one.
    private static func chatId(of destination: AppDestination) -> Int64? {
        switch destination {
        case .chat(let id): return id
        case .searchResult(let chat, _): return chat.id
        case .resolvedChat(let chat): return chat.id
        default: return nil
        }
    }

    /// Shows a chat from inside a chat screen (a bot's button, a t.me link).
    /// A chat the stack already shows is returned to, not stacked again: the
    /// bots of two chats that link to each other would otherwise add a screen
    /// and its drawn rows to the stack on every hop, and two screens of one
    /// chat would share one history. Returning pops the screens above it, and
    /// the chat keeps its scroll position.
    func showChat(_ chatId: Int64, route: AppDestination) {
        for index in path.indices.reversed() where Self.chatId(of: path[index]) == chatId {
            path = Array(path[...index])
            return
        }
        push(route)
    }

    /// System editors may cover a chat without changing its navigation route.
    func containsChat(_ chatId: Int64) -> Bool {
        path.contains { Self.chatId(of: $0) == chatId }
    }

    /// True when the chat is the visible (top-most) route.
    func isTopChat(_ chatId: Int64) -> Bool {
        guard let top = path.last else { return false }
        return Self.chatId(of: top) == chatId
    }

    /// Navigate to a chat by id. Used for deep-links (notification tap,
    /// widget URL scheme) where only chatId is known.
    func openChat(_ chatId: Int64) {
        // popToRoot + push in one synchronous swap so SwiftUI observes a
        // single state mutation. The previous dance (deferred push
        // with 100ms sleep) is unnecessary now that we own the path array
        // directly - SwiftUI processes the assignment atomically.
        path = [.chat(chatId)]
    }

    /// Navigate to a chat with a resolved ChatInfo. Preserves the
    /// original openChat(ChatInfo) call sites.
    func openChat(_ chat: ChatInfo) {
        openChat(chat.id)
    }

    /// Parse a orbitext://chat/<id> deep-link URL. Returns the chatId
    /// on a valid URL, nil otherwise. Shared by widget (.onOpenURL) and
    /// any future URL-driven entry point.
    static func chatId(fromDeepLink url: URL) -> Int64? {
        guard url.scheme == "orbitext",
              url.host == "chat",
              let raw = url.pathComponents.dropFirst().first,
              let chatId = Int64(raw) else { return nil }
        return chatId
    }
}
