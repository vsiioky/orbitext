@preconcurrency import UserNotifications

/// A user action on a delivered message notification.
enum NotificationAction: Equatable {
    static let replyIdentifier = "REPLY"
    static let markReadIdentifier = "MARK_READ"

    case reply(chatId: Int64, text: String)
    case markRead(chatId: Int64)
    case openChat(chatId: Int64)

    init?(identifier: String, chatId: Int64, userText: String?) {
        switch identifier {
        case Self.replyIdentifier:
            guard let userText else { return nil }
            self = .reply(chatId: chatId, text: userText)
        case Self.markReadIdentifier:
            self = .markRead(chatId: chatId)
        case UNNotificationDefaultActionIdentifier:
            self = .openChat(chatId: chatId)
        default:
            return nil
        }
    }
}

protocol NotificationManaging: AnyObject {
    var isAuthorized: Bool { get }
    var activeChatId: Int64? { get set }
    /// Awaited before the system completion handler runs: watchOS may suspend
    /// the app right after it, so the handler must finish its work first.
    var onReply: (@MainActor (_ chatId: Int64, _ text: String) async -> Void)? { get set }
    var onMarkRead: (@MainActor (_ chatId: Int64) async -> Void)? { get set }
    var onOpenChat: ((_ chatId: Int64) -> Void)? { get set }
    var hasLaunchedBefore: Bool { get set }

    /// On the main actor, which reads `isAuthorized`.
    @MainActor
    func requestPermission() async
    @MainActor
    func checkStatus() async
    func postMessageNotification(
        chatTitle: String,
        senderName: String,
        preview: String,
        chatId: Int64,
        messageKey: String?,
        playSound: Bool
    )
    func clearNotifications(for chatId: Int64)
    func registerCategories()
}

final class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate, NotificationManaging {
    static let shared = NotificationManager()
    private(set) var isAuthorized = false
    private let preferences: any AppPreferencesStoring
    private let center: any NotificationCenterClient

    /// The chat currently being viewed - suppress notifications for this chat
    var activeChatId: Int64?

    /// Callback for handling reply actions from notifications.
    var onReply: (@MainActor (_ chatId: Int64, _ text: String) async -> Void)?
    /// Callback for handling mark-as-read actions from notifications.
    var onMarkRead: (@MainActor (_ chatId: Int64) async -> Void)?
    /// Callback for the default tap action - navigate to the chat.
    var onOpenChat: ((_ chatId: Int64) -> Void)?

    /// Minimum interval between notification sounds (seconds). Every message
    /// is still shown; a burst plays one sound instead of dropping messages.
    private let soundCooldownInterval: TimeInterval = 3.0
    private var lastSoundTime: Date = .distantPast
    private var recentNotificationKeys: [String: Date] = [:]

    /// First launch: suppress all notifications until the user has used the app once
    var hasLaunchedBefore: Bool {
        get { preferences.notificationsHaveLaunchedBefore }
        set { preferences.setNotificationsHaveLaunchedBefore(newValue) }
    }

    init(
        preferences: any AppPreferencesStoring = AppPreferencesStore(),
        center: any NotificationCenterClient = SystemNotificationCenterClient()
    ) {
        self.preferences = preferences
        self.center = center
        super.init()
        center.delegate = self
    }

    @MainActor
    func requestPermission() async {
        do {
            isAuthorized = try await center.requestAuthorization()
        } catch {
            isAuthorized = false
        }
    }

    @MainActor
    func checkStatus() async {
        isAuthorized = await Self.canPostNotifications(with: center.authorizationStatus())
    }

    private static func canPostNotifications(with status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func postMessageNotification(
        chatTitle: String,
        senderName: String,
        preview: String,
        chatId: Int64,
        messageKey: String?,
        playSound: Bool
    ) {
        guard preferences.messageNotificationsEnabled, isAuthorized else { return }

        // Suppress all notifications on first launch
        guard hasLaunchedBefore else { return }

        pruneRecentNotificationKeys()
        if let messageKey {
            guard recentNotificationKeys[messageKey] == nil else { return }
            recentNotificationKeys[messageKey] = Date()
        }

        let now = Date()
        let playsSound = playSound && now.timeIntervalSince(lastSoundTime) >= soundCooldownInterval
        if playsSound {
            lastSoundTime = now
        }

        let content = UNMutableNotificationContent()
        content.title = chatTitle
        content.subtitle = senderName
        content.body = preview
        content.sound = playsSound ? .default : nil
        content.threadIdentifier = "chat_\(chatId)"
        content.categoryIdentifier = "MESSAGE"
        content.userInfo = ["chatId": chatId]

        let request = UNNotificationRequest(
            identifier: "msg_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func pruneRecentNotificationKeys() {
        let cutoff = Date().addingTimeInterval(-3600)
        recentNotificationKeys = recentNotificationKeys.filter { $0.value >= cutoff }
        // Cap at 500 entries to prevent unbounded growth in high-notification scenarios
        if recentNotificationKeys.count > 500 {
            let sorted = recentNotificationKeys.sorted { $0.value < $1.value }
            recentNotificationKeys = Dictionary(uniqueKeysWithValues: sorted.suffix(400))
        }
    }

    /// Remove delivered notifications for a specific chat
    func clearNotifications(for chatId: Int64) {
        center.removeDeliveredNotifications(inThread: "chat_\(chatId)")
    }

    func clearBadge() {
        center.clearBadge()
    }

    func registerCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationAction.replyIdentifier,
            title: L10n.string("Reply"),
            textInputButtonTitle: L10n.string("Send"),
            textInputPlaceholder: L10n.string("Message")
        )
        let markReadAction = UNNotificationAction(
            identifier: NotificationAction.markReadIdentifier,
            title: L10n.string("Mark as Read")
        )
        let category = UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        guard let chatId = userInfo["chatId"] as? Int64,
              let action = NotificationAction(identifier: response.actionIdentifier, chatId: chatId, userText: userText) else {
            completionHandler()
            return
        }
        handle(action, completionHandler: completionHandler)
    }

    /// Completes only after the action finishes: watchOS may suspend the app
    /// as soon as the completion runs. Handlers capture @MainActor state.
    func handle(_ action: NotificationAction, completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            await self.perform(action)
            completionHandler()
        }
    }

    @MainActor
    func perform(_ action: NotificationAction) async {
        switch action {
        case .reply(let chatId, let text):
            await onReply?(chatId, text)
        case .markRead(let chatId):
            await onMarkRead?(chatId)
        case .openChat(let chatId):
            onOpenChat?(chatId)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let chatId = notification.request.content.userInfo["chatId"] as? Int64
        // Dispatch to MainActor - activeChatId is written from @MainActor
        Task { @MainActor in
            completionHandler(self.foregroundPresentationOptions(chatId: chatId))
        }
    }

    func foregroundPresentationOptions(chatId: Int64?) -> UNNotificationPresentationOptions {
        guard preferences.messageNotificationsEnabled else { return [] }
        if let chatId, chatId == activeChatId { return [] }
        return [.sound, .banner]
    }
}
