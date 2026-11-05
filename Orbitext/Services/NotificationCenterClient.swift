@preconcurrency import UserNotifications

/// Keeps notification tests away from the user's shared notification center.
protocol NotificationCenterClient: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    /// Awaited by NotificationManager on the main actor.
    @MainActor
    func requestAuthorization() async throws -> Bool
    @MainActor
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest)
    /// Removes the delivered notifications of one thread, once the center
    /// has listed them.
    func removeDeliveredNotifications(inThread threadIdentifier: String)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func clearBadge()
}

final class SystemNotificationCenterClient: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    @MainActor
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) {
        center.add(request, withCompletionHandler: nil)
    }

    func removeDeliveredNotifications(inThread threadIdentifier: String) {
        center.getDeliveredNotifications { [center] notifications in
            let ids = notifications
                .filter { $0.request.content.threadIdentifier == threadIdentifier }
                .map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func clearBadge() {
        #if os(iOS)
        center.setBadgeCount(0)
        #endif
    }
}
