import Foundation
import Synchronization
@testable import OrbitextWatch

enum TestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

final class MockNotificationManager: NotificationManaging {
    var isAuthorized = false
    var activeChatId: Int64?
    var onReply: (@MainActor (_ chatId: Int64, _ text: String) async -> Void)?
    var onMarkRead: (@MainActor (_ chatId: Int64) async -> Void)?
    var onOpenChat: ((_ chatId: Int64) -> Void)?
    var hasLaunchedBefore = false

    var registerCategoriesCallCount = 0
    var checkStatusCallCount = 0
    var requestPermissionCallCount = 0
    var postedNotifications: [
        (
            chatTitle: String,
            senderName: String,
            preview: String,
            chatId: Int64,
            messageKey: String?,
            playSound: Bool
        )
    ] = []
    var clearedChatIds: [Int64] = []

    func requestPermission() async {
        requestPermissionCallCount += 1
    }

    func checkStatus() async {
        checkStatusCallCount += 1
    }

    func postMessageNotification(
        chatTitle: String,
        senderName: String,
        preview: String,
        chatId: Int64,
        messageKey: String?,
        playSound: Bool
    ) {
        postedNotifications.append((chatTitle, senderName, preview, chatId, messageKey, playSound))
    }

    func clearNotifications(for chatId: Int64) {
        clearedChatIds.append(chatId)
    }

    func registerCategories() {
        registerCategoriesCallCount += 1
    }
}

final class MockWidgetSync: WidgetSyncing {
    var updates: [(chatCount: Int, totalUnread: Int, isInBackground: Bool)] = []

    func update(chats: [ChatInfo], isInBackground: Bool) {
        updates.append((chats.count, chats.reduce(0) { $0 + $1.unreadCount }, isInBackground))
    }
}

/// Set from the `onChange` of an observation, which may be called from anywhere.
final class ObservationFlag: Sendable {
    private let raised = Mutex(false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() {
        raised.withLock { $0 = true }
    }
}

func makeTestDefaults() -> UserDefaults {
    let suiteName = "OrbitextTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

extension UserInfo {
    /// A user the transport knows by name.
    static func sample(id: Int64, firstName: String, lastName: String = "") -> UserInfo {
        UserInfo(tdApi: TDApi.decodeUser(TDJSONSample.object(
            TDJSONSample.user(id: id, firstName: firstName, lastName: lastName)
        )))
    }
}

extension MessageContent {
    /// Content as TDLib sends it, decoded and mapped the way parseMessageInfo does.
    static func parsed(_ dict: [String: Any]?) -> MessageContent {
        guard let dict else { return .unsupported("unknown") }
        return MessageContent(tdApi: TDApi.decodeMessageContent(dict))
    }
}
