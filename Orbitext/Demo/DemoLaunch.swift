#if DEBUG
import Foundation
import os

/// Demo mode: the app runs on `DemoTelegramService` with invented data, signed
/// in, with no network and no account, to take screenshots in the simulator.
///
/// It exists only in Debug builds (every file in `Orbitext/Demo` is wrapped in
/// `#if DEBUG`, which `scripts/verify.sh` checks) and starts only on request:
///
///     xcrun simctl launch <udid> <bundle id> -OrbitextDemo -OrbitextDemoScreen chat
///
/// Arguments (each also reads an environment variable, for `SIMCTL_CHILD_`):
/// - `-OrbitextDemo`, or `ORBITEXT_DEMO=1`: turns demo mode on. Without it the
///   other two are ignored.
/// - `-OrbitextDemoScreen <name>`, or `ORBITEXT_DEMO_SCREEN`: the screen to open
///   on, one of `Screen`. The default is the chat list.
/// - `-OrbitextDemoOpenChat <id>`, or `ORBITEXT_DEMO_OPEN_CHAT`: opens that chat
///   instead of the screen's route. Chat ids are in `DemoContent`.
struct DemoLaunch: Equatable, Sendable {
    enum Screen: String, CaseIterable, Sendable {
        case chatList
        case chat
        /// The chat opened at the photo and at the voice note, which sit above
        /// the bottom of the conversation.
        case chatPhoto
        case chatVoice
        /// The sticker picker, which renders from local data.
        case media
        case photo
        case attachments
        case signIn
        case signInQR
        case settings
        case contacts
        case profile
    }

    static let flag = "-OrbitextDemo"
    static let screenKey = "-OrbitextDemoScreen"
    static let openChatKey = "-OrbitextDemoOpenChat"
    static let environmentFlag = "ORBITEXT_DEMO"
    static let environmentScreenKey = "ORBITEXT_DEMO_SCREEN"
    static let environmentOpenChatKey = "ORBITEXT_DEMO_OPEN_CHAT"

    let screen: Screen
    let openChatId: Int64?

    /// Nil unless the process was asked for demo mode. An unknown screen name
    /// falls back to the chat list rather than failing the launch.
    init?(arguments: [String], environment: [String: String]) {
        let isOn = arguments.contains(Self.flag) || environment[Self.environmentFlag] == "1"
        guard isOn else { return nil }
        let screenName = Self.value(of: Self.screenKey, in: arguments) ?? environment[Self.environmentScreenKey]
        let chatText = Self.value(of: Self.openChatKey, in: arguments) ?? environment[Self.environmentOpenChatKey]
        screen = screenName.flatMap(Screen.init(rawValue:)) ?? .chatList
        openChatId = chatText.flatMap { Int64($0) }
    }

    private static func value(of key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The launch of this process, nil outside demo mode.
    static var current: DemoLaunch? {
        let info = ProcessInfo.processInfo
        return DemoLaunch(arguments: info.arguments, environment: info.environment)
    }

    /// What the service shows first: the sign-in screens need no account.
    var startup: DemoTelegramService.Startup {
        switch screen {
        case .signIn: .signIn
        case .signInQR: .qrLogin
        default: .signedIn
        }
    }

    /// The screens pushed over the chat list once the app is signed in.
    func route(in content: DemoContent) -> [AppDestination] {
        if let openChatId { return [.chat(openChatId)] }
        let alex = DemoContent.alexId
        guard let alexChat = content.chats.first(where: { $0.id == alex }) else { return [] }
        switch screen {
        case .chatList, .signIn, .signInQR: return []
        case .chat: return [.chat(alex)]
        case .chatPhoto: return [.searchResult(chat: alexChat, messageId: DemoContent.alexPhotoMessageId)]
        case .chatVoice: return [.searchResult(chat: alexChat, messageId: DemoContent.alexVoiceMessageId)]
        case .media: return [.stickerPicker(chatId: alex)]
        case .photo: return [.mediaViewer(fileId: DemoMedia.photoFileId)]
        case .attachments: return [.attachments(chatId: alex)]
        case .settings: return [.settings]
        case .contacts: return [.contacts]
        case .profile: return [.profile(alexChat)]
        }
    }
}

extension DemoLaunch {
    /// The app state for a demo launch. The TDLib transport is never created.
    @MainActor
    func makeAppState() -> AppState {
        Self.removeSavedSession()
        let content = DemoContent()
        let appState = AppState(
            service: DemoTelegramService(content: content, startup: startup),
            notificationManager: NotificationManager(center: DemoNotificationCenter())
        )
        appState.router.replace(with: route(in: content))
        return appState
    }

    /// Chat lists, contacts, drafts and queued messages of an earlier run, so
    /// every demo launch starts from the same content.
    private static func removeSavedSession() {
        let directory = ListCache<ChatInfo>.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let saved: Set = ["drafts.json", "pending_messages.json"]
        for name in names where name.hasPrefix("cached_") || saved.contains(name) {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                Logger.app.warning("Demo: could not remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
