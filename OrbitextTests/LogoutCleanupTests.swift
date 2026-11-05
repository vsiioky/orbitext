import XCTest
@testable import OrbitextWatch

@MainActor
final class LogoutCleanupTests: XCTestCase {
    func testLogoutClearsAppOwnedSessionData() async {
        let service = MockTelegramService()
        service.authState = .ready
        let defaults = makeTestDefaults()
        let preferences = AppPreferencesStore(defaults: defaults)
        let widgetSync = MockWidgetSync()
        let appState = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: widgetSync,
            preferences: preferences
        )

        appState.authManager.authState = .ready
        appState.chatRepository.chats = [
            ChatInfo(id: 42, title: "Alice", lastMessage: nil, unreadCount: 1, isGroup: false, isMuted: false, order: 1)
        ]
        appState.chatRepository.folders = [
            ChatFolder(id: 7, title: "Work", iconName: "folder", chatIds: [42])
        ]
        appState.chatRepository.isInitialSyncComplete = true
        appState.chatRepository.folderFilterEnabled = true
        appState.chatRepository.selectedFolderId = 7
        appState.chatRepository.saveDraft(chatId: 42, text: "local draft")
        appState.messageManager.messageQueue.enqueue(chatId: 42, text: "queued message")
        appState.messageManager.cachedContacts = [
            ContactInfo(id: 42, firstName: "Alice", lastName: "", phone: "", username: "alice", isOnline: false)
        ]
        defaults.set(AppLanguage.ru.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(true, forKey: "notif_hasLaunchedBefore")

        await appState.logout()

        XCTAssertEqual(service.logoutCallCount, 1)
        XCTAssertEqual(appState.authManager.authState, .waitPhoneNumber)
        XCTAssertTrue(appState.chatRepository.chats.isEmpty)
        XCTAssertTrue(appState.chatRepository.folders.isEmpty)
        XCTAssertFalse(appState.chatRepository.isInitialSyncComplete)
        XCTAssertFalse(appState.chatRepository.folderFilterEnabled)
        XCTAssertEqual(appState.chatRepository.selectedFolderId, 0)
        XCTAssertTrue(appState.chatRepository.draftStore.allDrafts().isEmpty)
        XCTAssertTrue(appState.messageManager.messageQueue.pendingMessages.isEmpty)
        XCTAssertNil(appState.messageManager.cachedContacts)
        XCTAssertNil(defaults.string(forKey: AppLanguage.storageKey))
        XCTAssertNil(defaults.object(forKey: "folderFilterEnabled"))
        XCTAssertNil(defaults.object(forKey: "selectedFolderId"))
        XCTAssertNil(defaults.object(forKey: "notif_hasLaunchedBefore"))
        XCTAssertEqual(widgetSync.updates.last?.chatCount, 0,
                       "The complication keeps showing the previous account's chat")
        XCTAssertEqual(widgetSync.updates.last?.totalUnread, 0)
        XCTAssertFalse(defaults.bool(forKey: "logoutCleanupPending"))
    }

    func testFailedLogoutLeavesLocalCleanupForNextLaunch() async {
        let service = MockTelegramService()
        service.logoutError = TestError.failed("native close timed out")
        let defaults = makeTestDefaults()
        let appState = AppState(service: service, notificationManager: MockNotificationManager(),
                                widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: defaults))

        await appState.logout()

        XCTAssertTrue(defaults.bool(forKey: "logoutCleanupPending"),
                      "logOut may already be in TDLib's binlog; the next launch must clear this account's data")
    }

    func testLaunchAfterInterruptedLogoutClearsPreviousAccountData() async {
        let service = MockTelegramService()
        service.authState = .waitPhoneNumber
        let defaults = makeTestDefaults()
        // The previous launch sent logOut and was killed before local cleanup.
        defaults.set(true, forKey: "logoutCleanupPending")
        let appState = AppState(service: service, notificationManager: MockNotificationManager(),
                                widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: defaults))
        appState.networkMonitor.pause()
        appState.chatRepository.saveDraft(chatId: 42, text: "previous account draft")
        appState.messageManager.messageQueue.enqueue(chatId: 42, text: "previous account message")
        defer { appState.messageManager.messageQueue.clear() }

        await appState.initialize()

        XCTAssertTrue(appState.chatRepository.draftStore.allDrafts().isEmpty,
                      "TDLib finishes the logout on this launch; the app must not keep its data")
        XCTAssertTrue(appState.messageManager.messageQueue.pendingMessages.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "logoutCleanupPending"))
        appState.eventTask?.cancel()
        appState.resetSyncPipeline()
    }

    func testOrdinaryLaunchKeepsAccountData() async {
        let service = MockTelegramService()
        service.authState = .ready
        let appState = AppState(service: service, notificationManager: MockNotificationManager(),
                                widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
        appState.networkMonitor.pause()
        appState.chatRepository.saveDraft(chatId: 42, text: "current draft")
        defer { appState.chatRepository.draftStore.clearAll() }

        await appState.initialize()

        XCTAssertEqual(appState.chatRepository.draftStore.allDrafts().count, 1)
        appState.eventTask?.cancel()
        appState.resetSyncPipeline()
    }
}
