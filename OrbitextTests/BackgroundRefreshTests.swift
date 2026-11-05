import Observation
import XCTest
@testable import OrbitextWatch

@MainActor
final class BackgroundRefreshTests: XCTestCase {
    override func setUp() async throws {
        // AppState restores the chat list a previous run of the host app left
        // on this simulator; the counts below assume an empty start.
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
    }

    func testLogoutTransitionsBackToAuthFlowAndClearsData() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 2, isGroup: false, isMuted: false, order: 1)
        ]
        service.folders = [
            ChatFolder(id: 1, title: "Work", iconName: "briefcase", chatIds: [])
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.chatRepository.chats = service.chats
        appState.chatRepository.folders = service.folders
        appState.chatRepository.isInitialSyncComplete = true
        appState.chatRepository.folderFilterEnabled = true
        appState.chatRepository.selectedFolderId = 1
        appState.authManager.authState = .ready

        await appState.logout()

        XCTAssertEqual(service.logoutCallCount, 1)
        XCTAssertEqual(appState.authManager.authState, .waitPhoneNumber)
        XCTAssertTrue(appState.chatRepository.chats.isEmpty)
        XCTAssertTrue(appState.chatRepository.folders.isEmpty)
        XCTAssertFalse(appState.chatRepository.isInitialSyncComplete)
        XCTAssertFalse(appState.chatRepository.folderFilterEnabled)
        XCTAssertEqual(appState.chatRepository.selectedFolderId, 0)
    }

    func testLogoutPreservesSessionDataWhenServiceThrows() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.logoutError = TestError.failed("boom")
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.chatRepository.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]
        appState.chatRepository.isInitialSyncComplete = true
        appState.authManager.authState = .ready

        await appState.logout()

        XCTAssertEqual(service.logoutCallCount, 1)
        XCTAssertEqual(appState.authManager.authState, .error("boom"))
        XCTAssertEqual(appState.chatRepository.chats.map(\.id), [1])
        XCTAssertTrue(appState.chatRepository.isInitialSyncComplete)
        XCTAssertNotNil(appState.errorPresenter.error)
    }

    func testSecondLoginLoadsChatsAfterLogoutReset() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 2, isGroup: false, isMuted: false, order: 1)
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.chatRepository.chats = service.chats
        appState.chatRepository.isInitialSyncComplete = true
        appState.authManager.authState = .ready

        await appState.logout()

        service.authState = .ready
        appState.authManager.authState = .ready
        appState.networkMonitor.updateTDLibState(.ready)
        await appState.ensureVisibleContentLoaded()

        XCTAssertEqual(service.getChatsRequests.count, 1)
        XCTAssertEqual(appState.chatRepository.chats.count, 1)
        XCTAssertTrue(appState.chatRepository.isInitialSyncComplete)
    }

    func testLogoutPreventsInFlightSyncFromRepopulatingChats() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.getChatsDelay = .milliseconds(100)
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 2, isGroup: false, isMuted: false, order: 1)
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.authManager.authState = .ready
        appState.enqueueSync(AppState.SyncRequest(
            loadChats: true,
            loadFolders: false,
            flushMessageQueue: false,
            requiresReadyConnection: false,
            reasons: ["test_in_flight_logout"]
        ))

        for _ in 0..<20 where service.getChatsRequests.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.getChatsRequests.count, 1)

        await appState.logout()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(service.logoutCallCount, 1)
        XCTAssertEqual(appState.authManager.authState, .waitPhoneNumber)
        XCTAssertTrue(appState.chatRepository.chats.isEmpty)
        XCTAssertFalse(appState.chatRepository.isInitialSyncComplete)
        // Logout empties the widget once; the cancelled sync must not refill it.
        XCTAssertEqual(widgetSync.updates.map(\.chatCount), [0])
    }

    func testBackgroundRefreshSkipsWhenNotAuthenticated() async {
        let service = MockTelegramService()
        service.authState = .waitPhoneNumber
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        await appState.performBackgroundRefresh()

        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(service.resumeCallCount, 0)
        XCTAssertEqual(service.getChatsRequests.count, 0)
        XCTAssertTrue(widgetSync.updates.isEmpty)
    }

    func testBackgroundRefreshDoesNotColdStartApp() async {
        let service = MockTelegramService()
        service.authState = .ready
        let appState = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        await appState.performBackgroundRefresh()

        XCTAssertFalse(appState.isInitialized)
        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(service.resumeCallCount, 0)
        XCTAssertEqual(service.getChatsRequests.count, 0)
    }

    func testBackgroundRefreshLoadsChatsWhenAuthenticated() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 2, isGroup: false, isMuted: false, order: 1)
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        // initialize() starts an independent event consumer; returning from
        // service.start() does not mean its queued auth event reached AppState.
        let authReady = expectation(description: "Initial auth event reaches AppState")
        withObservationTracking {
            _ = appState.authManager.authState
        } onChange: {
            authReady.fulfill()
        }
        await appState.initialize()
        await fulfillment(of: [authReady], timeout: 2)
        guard appState.authManager.authState == .ready else {
            return XCTFail("Background refresh requires the initial ready auth event")
        }

        await appState.performBackgroundRefresh()

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.resumeCallCount, 1)
        // Started without a scene or a lease, the client sleeps at once; the
        // refresh's lease wakes it and puts it back to sleep at the end.
        XCTAssertEqual(service.suspendCallCount, 2)
        XCTAssertEqual(service.getChatsRequests.count, 1)
        XCTAssertEqual(appState.chatRepository.chats.count, 1)
        XCTAssertEqual(widgetSync.updates.last?.chatCount, 1)
        XCTAssertTrue(widgetSync.updates.last?.isInBackground ?? false)
    }

    func testHandleRemotePushLoadsChatsWhenAuthenticated() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.remotePushResult = true
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 1)
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        await appState.initialize()
        await Task.yield()

        let result = await appState.handleRemotePush(userInfo: [
            "aps": ["content-available": 1],
            "p": "payload"
        ])

        XCTAssertEqual(result, .newData)
        XCTAssertEqual(service.handledRemotePushPayloads.count, 1)
        XCTAssertEqual(service.handledRemotePushPayloads.first?["p"] as? String, "payload")
        XCTAssertEqual(service.resumeCallCount, 1)
        // Started without a scene or a lease, the client sleeps at once; the
        // refresh's lease wakes it and puts it back to sleep at the end.
        XCTAssertEqual(service.suspendCallCount, 2)
        XCTAssertEqual(service.getChatsRequests.count, 1)
        XCTAssertEqual(appState.chatRepository.chats.count, 1)
        XCTAssertEqual(widgetSync.updates.last?.chatCount, 1)
        XCTAssertTrue(widgetSync.updates.last?.isInBackground ?? false)
    }

    func testHandleRemotePushLoadsChatsWithoutReadyConnectionEvent() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.remotePushResult = true
        service.emitReadyConnectionOnStart = false
        service.emitReadyConnectionOnResume = false
        service.chats = [
            ChatInfo(id: 1, title: "Alice", lastMessage: nil, unreadCount: 4, isGroup: false, isMuted: false, order: 1)
        ]
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.isInitialized = true
        appState.authManager.authState = .ready

        let result = await appState.handleRemotePush(userInfo: [
            "aps": ["content-available": 1],
            "p": "payload"
        ])

        XCTAssertEqual(result, .newData)
        XCTAssertEqual(service.getChatsRequests.count, 1)
        XCTAssertEqual(appState.chatRepository.chats.count, 1)
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 4)
        XCTAssertTrue(widgetSync.updates.last?.isInBackground ?? false)
    }

    func testRemotePushDoesNotColdStartApp() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.remotePushResult = true
        let appState = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        let result = await appState.handleRemotePush(userInfo: ["aps": ["content-available": 1]])

        XCTAssertEqual(result, .noData)
        XCTAssertFalse(appState.isInitialized)
        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(service.handledRemotePushPayloads.count, 0)
        XCTAssertEqual(service.getChatsRequests.count, 0)
    }

    func testSyncRequestFactoryPreservesLifecycleDecisions() {
        let foreground = AppState.SyncRequestFactory.becameActive(shouldReloadChats: true)
        XCTAssertTrue(foreground.loadChats)
        XCTAssertFalse(foreground.loadFolders)
        XCTAssertTrue(foreground.flushMessageQueue)
        XCTAssertTrue(foreground.requiresReadyConnection)
        XCTAssertEqual(foreground.reasons, Set(["became_active"]))

        let initialForeground = AppState.SyncRequestFactory.becameActive(shouldReloadChats: false)
        XCTAssertFalse(initialForeground.loadChats)
        XCTAssertTrue(initialForeground.flushMessageQueue)

        let background = AppState.SyncRequestFactory.backgroundRefresh(shouldLoadFolders: true)
        XCTAssertTrue(background.loadChats)
        XCTAssertTrue(background.loadFolders)
        XCTAssertFalse(background.flushMessageQueue)
        XCTAssertFalse(background.requiresReadyConnection)
        XCTAssertEqual(background.reasons, Set(["background_refresh"]))
    }

    func testSyncRequestFactoryPreservesRemotePushGateDecision() {
        let request = AppState.SyncRequestFactory.remotePush()

        XCTAssertTrue(request.loadChats)
        XCTAssertFalse(request.loadFolders)
        XCTAssertFalse(request.flushMessageQueue)
        XCTAssertFalse(request.requiresReadyConnection)
        XCTAssertEqual(request.reasons, Set(["remote_push"]))
    }

    func testNotificationPresentationPolicySuppressesActiveChat() {
        let info = RemoteNotificationInfo(
            chatId: 77,
            chatTitle: "Fallback",
            senderName: "Alice",
            preview: "Ping",
            notificationKey: "push:77:1",
            playSound: true
        )

        let decision = AppState.NotificationPresentationPolicy.decision(
            info: info,
            matchingChat: nil,
            activeChatId: 77,
            isInSelectedFolder: nil
        )

        XCTAssertFalse(decision.shouldPost)
        XCTAssertEqual(decision.suppressionReason, .activeChat)
    }

    func testNotificationPresentationPolicySuppressesMutedChat() {
        let info = RemoteNotificationInfo(
            chatId: 77,
            chatTitle: "Fallback",
            senderName: "Alice",
            preview: "Ping",
            notificationKey: "push:77:1",
            playSound: true
        )
        let chat = ChatInfo(id: 77, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: true, order: 1)

        let decision = AppState.NotificationPresentationPolicy.decision(
            info: info,
            matchingChat: chat,
            activeChatId: nil,
            isInSelectedFolder: nil
        )

        XCTAssertFalse(decision.shouldPost)
        XCTAssertEqual(decision.suppressionReason, .mutedChat)
    }

    func testNotificationPresentationPolicySuppressesChatsOutsideSelectedFolder() {
        let info = RemoteNotificationInfo(
            chatId: 77,
            chatTitle: "Fallback",
            senderName: "Alice",
            preview: "Ping",
            notificationKey: "push:77:1",
            playSound: true
        )

        let decision = AppState.NotificationPresentationPolicy.decision(
            info: info,
            matchingChat: nil,
            activeChatId: nil,
            isInSelectedFolder: false
        )

        XCTAssertFalse(decision.shouldPost)
        XCTAssertEqual(decision.suppressionReason, .outsideSelectedFolder)
    }

    func testNotificationPresentationPolicyAllowsFirstLaunchSuppressionToRemainInNotificationManager() {
        let info = RemoteNotificationInfo(
            chatId: 77,
            chatTitle: "Fallback",
            senderName: "Alice",
            preview: "Ping",
            notificationKey: "push:77:1",
            playSound: true
        )

        let decision = AppState.NotificationPresentationPolicy.decision(
            info: info,
            matchingChat: nil,
            activeChatId: nil,
            isInSelectedFolder: nil
        )

        XCTAssertTrue(decision.shouldPost)
        XCTAssertNil(decision.suppressionReason)
    }

    func testRemoteNotificationEventPostsLocalNotification() async {
        let service = MockTelegramService()
        service.authState = .ready
        let widgetSync = MockWidgetSync()
        let notificationManager = MockNotificationManager()
        let appState = AppState(
            service: service,
            notificationManager: notificationManager,
            widgetSync: widgetSync,
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        appState.chatRepository.chats = [
            ChatInfo(id: 77, title: "Alice", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        ]

        await appState.initialize()
        await Task.yield()

        service.emit(.remoteNotification(RemoteNotificationInfo(
            chatId: 77,
            chatTitle: "Fallback",
            senderName: "Alice",
            preview: "Ping",
            notificationKey: "push:77:1",
            playSound: false
        )))
        for _ in 0..<20 where notificationManager.postedNotifications.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(notificationManager.postedNotifications.count, 1)
        XCTAssertEqual(notificationManager.postedNotifications.first?.chatTitle, "Alice")
        XCTAssertEqual(notificationManager.postedNotifications.first?.senderName, "Alice")
        XCTAssertEqual(notificationManager.postedNotifications.first?.preview, "Ping")
        XCTAssertEqual(notificationManager.postedNotifications.first?.chatId, 77)
        XCTAssertEqual(notificationManager.postedNotifications.first?.messageKey, "push:77:1")
        XCTAssertEqual(notificationManager.postedNotifications.first?.playSound, false)
    }
}

@MainActor
final class NetworkMonitorTests: XCTestCase {
    func testConnectionStatusUsesReachabilityWhenNetworkIsAvailable() {
        let monitor = NetworkMonitor(startMonitoring: false)

        monitor.applyNetworkPathUpdate(isSatisfied: true, connectionType: .wifi)
        monitor.updateTDLibState(.updating)

        XCTAssertEqual(monitor.connectionStatus, .connected)
        XCTAssertEqual(monitor.connectionType, .wifi)
        XCTAssertFalse(monitor.isConnected)
    }

    func testConnectionStatusIsConnectingWhenTDLibWaitsButNetworkAvailable() {
        let monitor = NetworkMonitor(startMonitoring: false)

        monitor.applyNetworkPathUpdate(isSatisfied: true, connectionType: .wifi)
        monitor.updateTDLibState(.waitingForNetwork)

        // NWPath says network is available → transient TDLib state → show connecting
        XCTAssertEqual(monitor.connectionStatus, .connecting)
        XCTAssertFalse(monitor.isConnected)
    }

    func testOtherInterfaceTypeIsReportedAsUnknown() {
        XCTAssertEqual(
            NetworkMonitor.connectionType(
                isSatisfied: true,
                usesWiFi: false,
                usesCellular: false,
                usesOther: true
            ),
            .unknown
        )
    }

    func testConnectionStatusIsOfflineWhenBothTDLibAndPathOffline() {
        let monitor = NetworkMonitor(startMonitoring: false)

        monitor.applyNetworkPathUpdate(isSatisfied: false, connectionType: .unknown)
        monitor.updateTDLibState(.waitingForNetwork)

        XCTAssertEqual(monitor.connectionStatus, .offline)
        XCTAssertFalse(monitor.isConnected)
    }

    func testOperationalReconnectStillRequiresReadyTDLib() {
        let monitor = NetworkMonitor(startMonitoring: false)
        var reconnectCount = 0
        monitor.onReconnected = { reconnectCount += 1 }

        monitor.applyNetworkPathUpdate(isSatisfied: false, connectionType: .unknown)
        monitor.updateTDLibState(.ready)
        XCTAssertEqual(reconnectCount, 0)

        monitor.applyNetworkPathUpdate(isSatisfied: true, connectionType: .wifi)
        XCTAssertEqual(reconnectCount, 1)
        XCTAssertTrue(monitor.isConnected)
    }
}
