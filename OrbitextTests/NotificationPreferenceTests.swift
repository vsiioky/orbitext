@preconcurrency import UserNotifications
import XCTest
@testable import OrbitextWatch

@MainActor
final class NotificationPreferenceTests: XCTestCase {
    func testDisabledPreferenceSurvivesRecreationAndAccountCleanup() {
        let defaults = makeTestDefaults()
        let preferences = AppPreferencesStore(defaults: defaults)
        XCTAssertTrue(preferences.messageNotificationsEnabled)
        preferences.setMessageNotificationsEnabled(false)

        let reopened = AppPreferencesStore(defaults: defaults)
        XCTAssertFalse(reopened.messageNotificationsEnabled)
        reopened.clearSessionPreferences()

        XCTAssertFalse(AppPreferencesStore(defaults: defaults).messageNotificationsEnabled)
        XCTAssertEqual(defaults.object(forKey: MessageNotificationPreference.storageKey) as? Bool, false)
    }

    func testDisabledPostingDoesNotConsumeDeduplicationOrCooldown() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()
        fixture.preferences.setMessageNotificationsEnabled(false)

        fixture.post(key: "same-message")
        XCTAssertTrue(fixture.center.requests.isEmpty)

        fixture.preferences.setMessageNotificationsEnabled(true)
        fixture.post(key: "same-message")
        XCTAssertEqual(fixture.center.requests.count, 1)
        XCTAssertEqual(fixture.center.requests.first?.content.categoryIdentifier, "MESSAGE")
    }

    func testSystemAuthorizationCannotOverrideDisabledPreference() async {
        let fixture = Fixture()
        fixture.preferences.setMessageNotificationsEnabled(false)

        await fixture.manager.checkStatus()
        await fixture.manager.requestPermission()
        fixture.post()

        XCTAssertTrue(fixture.manager.isAuthorized)
        XCTAssertFalse(fixture.preferences.messageNotificationsEnabled)
        XCTAssertTrue(fixture.center.requests.isEmpty)
        XCTAssertEqual(fixture.center.permissionRequests, 1)
    }

    func testPermissionCompletionAfterDisableDoesNotEnableMessages() async {
        let fixture = Fixture()
        let gate = PermissionGate()
        fixture.center.permissionOperation = { await gate.wait() }
        let permission = Task { await fixture.manager.requestPermission() }
        await gate.waitUntilRequested()

        fixture.preferences.setMessageNotificationsEnabled(false)
        await gate.resolve(true)
        await permission.value
        fixture.post()

        XCTAssertTrue(fixture.manager.isAuthorized)
        XCTAssertFalse(fixture.preferences.messageNotificationsEnabled)
        XCTAssertTrue(fixture.center.requests.isEmpty)
    }

    func testEnabledPreferenceStillRequiresSystemAuthorization() async {
        let fixture = Fixture()
        fixture.center.status = .denied
        await fixture.manager.checkStatus()

        fixture.post()

        XCTAssertTrue(fixture.preferences.messageNotificationsEnabled)
        XCTAssertFalse(fixture.manager.isAuthorized)
        XCTAssertTrue(fixture.center.requests.isEmpty)
    }

    func testForegroundPresentationChecksCurrentPreferenceAndActiveChat() {
        let fixture = Fixture()
        fixture.manager.activeChatId = 42
        XCTAssertEqual(fixture.manager.foregroundPresentationOptions(chatId: 42), [])
        XCTAssertEqual(fixture.manager.foregroundPresentationOptions(chatId: 43), [.sound, .banner])
        XCTAssertEqual(fixture.manager.foregroundPresentationOptions(chatId: nil), [.sound, .banner])

        fixture.preferences.setMessageNotificationsEnabled(false)

        XCTAssertEqual(fixture.manager.foregroundPresentationOptions(chatId: 43), [])
        XCTAssertEqual(fixture.manager.foregroundPresentationOptions(chatId: nil), [])
    }

    func testRemoteNotificationEventUsesSamePersistedPostingGate() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()
        let app = AppState(service: MockTelegramService(), notificationManager: fixture.manager,
                           widgetSync: MockWidgetSync(), preferences: fixture.preferences)
        defer {
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            app.chatRepository.invalidateChatListPrefetch()
        }
        let notification = RemoteNotificationInfo(chatId: 42, chatTitle: "Offline fixture",
                                                senderName: "Fixture", preview: "Test message",
                                                notificationKey: "push-fixture", playSound: true)
        fixture.preferences.setMessageNotificationsEnabled(false)

        await app.handleRemoteNotificationEvent(notification)
        XCTAssertTrue(fixture.center.requests.isEmpty)

        fixture.preferences.setMessageNotificationsEnabled(true)
        await app.handleRemoteNotificationEvent(notification)
        XCTAssertEqual(fixture.center.requests.count, 1)
    }

    func testInjectedCenterOwnsDelegateAndFirstLaunchStateIsIsolated() async {
        let fixture = Fixture()
        XCTAssertTrue(fixture.center.delegate === fixture.manager)
        fixture.manager.hasLaunchedBefore = false
        await fixture.manager.checkStatus()
        fixture.post()
        XCTAssertTrue(fixture.center.requests.isEmpty)

        fixture.manager.hasLaunchedBefore = true
        fixture.post()
        XCTAssertEqual(fixture.center.requests.count, 1)
        XCTAssertTrue(fixture.preferences.notificationsHaveLaunchedBefore)
    }

    // MARK: - Presentation policy

    func testCooldownSilencesARapidSecondMessageInsteadOfDroppingIt() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()

        fixture.post(key: "42:1")
        fixture.post(key: "42:2")

        XCTAssertEqual(fixture.center.requests.count, 2, "The second message within 3 s was never shown")
        XCTAssertNotNil(fixture.center.requests.first?.content.sound)
        XCTAssertNil(fixture.center.requests.last?.content.sound, "Only the sound is rate-limited")
    }

    func testChatOfSelectedFolderIsNotSuppressedBeforeTheFolderListLoads() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()
        let app = AppState(service: MockTelegramService(), notificationManager: fixture.manager,
                           widgetSync: MockWidgetSync(), preferences: fixture.preferences)
        defer {
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            app.chatRepository.invalidateChatListPrefetch()
        }
        // A folder is selected, but this launch has not loaded its chats yet.
        app.chatRepository.folders = [ChatFolder(id: 7, title: "Work", iconName: "folder", chatIds: [])]
        app.chatRepository.folderFilterEnabled = true
        app.chatRepository.selectedFolderId = 7
        app.chatRepository.notificationFolderWait = .milliseconds(50)

        await app.handleRemoteNotificationEvent(RemoteNotificationInfo(
            chatId: 99, chatTitle: "Colleague", senderName: "Bob", preview: "Ping",
            notificationKey: "99:1", playSound: true))

        XCTAssertEqual(fixture.center.requests.count, 1,
                       "Membership is unknown, so the notification must not be suppressed")
    }

    func testFolderMembershipBeyondTheLoadedPageComesFromTDLibPositions() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()
        let service = MockTelegramService()
        service.chatFolderIdsByChatId = [99: [7]]
        let app = AppState(service: service, notificationManager: fixture.manager,
                           widgetSync: MockWidgetSync(), preferences: fixture.preferences)
        defer {
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            app.chatRepository.invalidateChatListPrefetch()
        }
        app.chatRepository.folders = [ChatFolder(id: 7, title: "Work", iconName: "folder", chatIds: [])]
        app.chatRepository.folderFilterEnabled = true
        app.chatRepository.selectedFolderId = 7
        // This client returned the first page of folder 7; chat 99 is further down.
        app.chatRepository.loadedChatListFolderId = 7
        app.chatRepository.folderListConfirmedByClient = 7

        await app.handleRemoteNotificationEvent(RemoteNotificationInfo(
            chatId: 99, chatTitle: "Colleague", senderName: "Bob", preview: "Ping",
            notificationKey: "99:1", playSound: true))
        XCTAssertEqual(fixture.center.requests.count, 1, "A folder chat beyond the loaded page was suppressed")

        // TDLib places chat 55 in no loaded folder: it is outside folder 7.
        await app.handleRemoteNotificationEvent(RemoteNotificationInfo(
            chatId: 55, chatTitle: "Shop", senderName: "Shop", preview: "Sale",
            notificationKey: "55:1", playSound: true))
        XCTAssertEqual(fixture.center.requests.count, 1, "A chat outside the selected folder was shown")
    }

    func testPushNotificationKeyMatchesTheMessageKey() async {
        let service = TDLibService()
        let received = Task { [events = service.events] () -> TDLibEvent? in
            for await event in events { return event }
            return nil
        }
        service.handleUpdate([
            "@type": "updateNotificationGroup",
            "chat_id": 42,
            "type": ["@type": "notificationGroupTypeMessages"] as [String: Any],
            "added_notifications": [[
                "@type": "notification", "id": 1, "is_silent": false,
                "type": [
                    "@type": "notificationTypeNewPushMessage", "message_id": 1_048_576,
                    "sender_name": "Alice", "is_outgoing": false,
                    "content": ["@type": "pushMessageContentText", "text": "Hi"] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]]
        ])
        let timeout = Task { try? await Task.sleep(for: .seconds(1))
        received.cancel()
        }
        let event = await received.value
        timeout.cancel()

        guard case .remoteNotification(let info) = event else {
            return XCTFail("Expected a remote notification event, got \(String(describing: event))")
        }
        XCTAssertEqual(info.notificationKey, "42:1048576",
                       "The same message notified via push and via TDLib must share one key")
    }

    func testRemoteNotificationOfAnEndedClientIsNotShown() async {
        let fixture = Fixture()
        await fixture.manager.checkStatus()
        let app = AppState(service: MockTelegramService(), notificationManager: fixture.manager,
                           widgetSync: MockWidgetSync(), preferences: fixture.preferences)
        defer {
            app.resetSyncPipeline()
            app.networkMonitor.pause()
        }
        let pushedBy = app.lifecycle.state.streamGeneration

        await app.logout()
        await app.handleRemoteNotificationEvent(RemoteNotificationInfo(
            chatId: 99, chatTitle: "Colleague", senderName: "Bob", preview: "Ping",
            notificationKey: "99:1", playSound: true), generation: pushedBy)

        XCTAssertTrue(fixture.center.requests.isEmpty,
                      "A push of the signed-out account was shown after logout")
    }

    func testNotificationActionsMapSystemIdentifiers() {
        XCTAssertEqual(NotificationAction(identifier: "REPLY", chatId: 42, userText: "Hi"),
                       .reply(chatId: 42, text: "Hi"))
        XCTAssertNil(NotificationAction(identifier: "REPLY", chatId: 42, userText: nil))
        XCTAssertEqual(NotificationAction(identifier: "MARK_READ", chatId: 42, userText: nil),
                       .markRead(chatId: 42))
        XCTAssertEqual(NotificationAction(identifier: UNNotificationDefaultActionIdentifier, chatId: 42, userText: nil),
                       .openChat(chatId: 42))
        XCTAssertNil(NotificationAction(identifier: UNNotificationDismissActionIdentifier, chatId: 42, userText: nil))
    }

    func testSystemCompletionWaitsForReplyHandler() async {
        let fixture = Fixture()
        let gate = PermissionGate()
        var replies: [String] = []
        var handlerStarted = false
        fixture.manager.onReply = { _, text in
            handlerStarted = true
            _ = await gate.wait()
            replies.append(text)
        }
        let completion = CompletionFlag()
        fixture.manager.handle(.reply(chatId: 42, text: "Hi")) { completion.set() }
        await waitUntil { handlerStarted }
        XCTAssertTrue(handlerStarted)
        // Let any wrongly early completion run before asserting it did not.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completion.isSet, "watchOS could suspend the app before the reply was sent")

        await gate.waitUntilRequested()
        await gate.resolve(true)
        await waitUntil { completion.isSet }
        XCTAssertTrue(completion.isSet)
        XCTAssertEqual(replies, ["Hi"])
    }

    /// The system calls the delegate through the Objective-C runtime. A Swift
    /// signature that stops matching the optional protocol method is no
    /// error: the method is just never called, and the notification actions
    /// and the foreground banner policy stop working.
    func testNotificationCenterReachesBothDelegateMethods() {
        let manager = Fixture().manager
        let didReceive = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        let willPresent = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))

        XCTAssertTrue(manager.responds(to: didReceive), "Notification actions would never reach the app")
        XCTAssertTrue(manager.responds(to: willPresent), "Banners in the open chat would not be suppressed")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    private final class Fixture {
        let preferences = AppPreferencesStore(defaults: makeTestDefaults())
        let center = FakeNotificationCenter()
        let manager: NotificationManager

        init() {
            manager = NotificationManager(preferences: preferences, center: center)
            manager.hasLaunchedBefore = true
        }

        func post(key: String = "fixture-message") {
            manager.postMessageNotification(chatTitle: "Offline fixture", senderName: "Fixture",
                                            preview: "Test message", chatId: 42,
                                            messageKey: key, playSound: true)
        }
    }

    private final class FakeNotificationCenter: NotificationCenterClient {
        weak var delegate: (any UNUserNotificationCenterDelegate)?
        var status: UNAuthorizationStatus = .authorized
        var requests: [UNNotificationRequest] = []
        var permissionRequests = 0
        var permissionOperation: (() async -> Bool)?

        func requestAuthorization() async throws -> Bool {
            permissionRequests += 1
            if let permissionOperation { return await permissionOperation() }
            return status == .authorized
        }

        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func add(_ request: UNNotificationRequest) { requests.append(request) }
        func removeDeliveredNotifications(inThread threadIdentifier: String) {}
        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
        func clearBadge() {}
    }

    /// Set from the completion the system would call on any thread.
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private actor PermissionGate {
        private var result: CheckedContinuation<Bool, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                result = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilRequested() async {
            if result != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func resolve(_ authorized: Bool) {
            result?.resume(returning: authorized)
            result = nil
        }
    }
}
