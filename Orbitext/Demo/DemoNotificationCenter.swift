#if DEBUG
@preconcurrency import UserNotifications

/// A notification center that is always allowed and delivers nothing, so demo
/// mode shows no system permission prompt and posts no real notification.
final class DemoNotificationCenter: NotificationCenterClient {
    var delegate: (any UNUserNotificationCenterDelegate)?

    func requestAuthorization() async throws -> Bool {
        true
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        .authorized
    }

    func add(_ request: UNNotificationRequest) {}

    func removeDeliveredNotifications(inThread threadIdentifier: String) {}

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}

    func clearBadge() {}
}
#endif
