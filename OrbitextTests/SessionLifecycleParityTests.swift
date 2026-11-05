import XCTest
@testable import OrbitextWatch

/// Restart, retry and local reset reach every transport through the session
/// lifecycle protocol, so the mock runs the same app paths as TDLibService.
/// The native twins of these tests are StartupAuthRetryTests and
/// TDNativeCloseTests.
@MainActor
final class SessionLifecycleParityTests: XCTestCase {
    private let chatId: Int64 = 9_123_456
    private let startupMessage = "keychain locked"
    private var restoredDraft: String?
    private var apps: [AppState] = []

    override func setUp() async throws {
        try await super.setUp()
        restoredDraft = DraftStore().getDraft(chatId: chatId)
    }

    override func tearDown() async throws {
        for app in apps {
            app.eventTask?.cancel()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        DraftStore().setDraft(chatId: chatId, text: restoredDraft)
        try await super.tearDown()
    }

    func testRetryAfterFailedStartRestartsWithoutWipingSession() async {
        let service = MockTelegramService()
        service.startError = TestError.failed(startupMessage)
        let app = makeApp(service: service)
        await app.initialize()
        await waitUntil { app.authManager.authState == .error(self.startupMessage) }
        seedSession(in: app)
        service.startError = nil

        await app.retry()

        XCTAssertEqual(service.retryStartupCallCount, 1)
        XCTAssertEqual(service.resetLocalSessionCallCount, 0, "A bootstrap failure is not a logout")
        XCTAssertEqual(service.startCallCount, 2)
        assertSessionKept(in: app)
        // The stale error is still showing until the restart's own event arrives.
        await waitUntil { app.authManager.authState == .waitPhoneNumber }
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
        XCTAssertFalse(app.authManager.isLoading)
    }

    func testRetryThatFailsAgainShowsTheNewError() async {
        let service = MockTelegramService()
        service.startError = TestError.failed(startupMessage)
        let app = makeApp(service: service)
        await app.initialize()
        await waitUntil { app.authManager.authState == .error(self.startupMessage) }
        seedSession(in: app)
        let stillLocked = "still locked"
        service.startError = TestError.failed(stillLocked)

        await app.retry()

        XCTAssertEqual(service.startCallCount, 2)
        assertSessionKept(in: app)
        // A message the first failure never showed: only the retry produces it.
        await waitUntil { app.authManager.authState == .error(stillLocked) }
        XCTAssertEqual(app.authManager.authState, .error(stillLocked))
        XCTAssertFalse(app.authManager.isLoading)
    }

    func testRetryAfterLogoutResetsInsteadOfRestarting() async {
        let service = MockTelegramService()
        service.startError = TestError.failed(startupMessage)
        let app = makeApp(service: service)
        await app.initialize()
        await waitUntil { app.authManager.authState == .error(self.startupMessage) }
        service.startError = nil

        await app.logout()
        await app.retry()

        XCTAssertEqual(service.retryStartupCallCount, 1)
        XCTAssertEqual(service.resetLocalSessionCallCount, 1,
                       "Logout ended the failed session: there is no startup left to retry")
        XCTAssertEqual(service.startCallCount, 2)
    }

    func testLogoutForgetsTheTransportsUser() async {
        let service = MockTelegramService()
        service.currentUserID = 77
        let app = makeApp(service: service)

        await app.logout()

        XCTAssertNil(service.currentUserID, "A signed-out transport knows no one")
        XCTAssertFalse(service.isSelfChat(chatId: 77))
    }

    func testRetryWithoutStartupFailureResetsTransportThenRestarts() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        await app.initialize()
        seedSession(in: app)

        await app.retry()

        XCTAssertEqual(service.retryStartupCallCount, 1, "The transport decides whether a restart is enough")
        XCTAssertEqual(service.resetLocalSessionCallCount, 1)
        XCTAssertEqual(service.startCallCount, 2)
        assertSessionCleared(in: app)
    }

    func testAuthResetAfterFailedLogoutResetsTransportSession() async {
        let service = MockTelegramService()
        service.logoutError = TestError.failed("close failed")
        let app = makeApp(service: service)
        seedSession(in: app)

        await app.logout()
        assertSessionKept(in: app)
        XCTAssertEqual(app.authManager.authState, .error("close failed"))

        await app.resetAuthMethodSelection()

        XCTAssertEqual(service.resetLocalSessionCallCount, 1,
                       "The local session survived: the next login would reuse the old account")
        assertSessionCleared(in: app)
    }

    func testFailedLocalSessionResetKeepsAppDataAndShowsError() async {
        let service = MockTelegramService()
        service.resetLocalSessionError = TestError.failed("database in use")
        let app = makeApp(service: service)
        seedSession(in: app)

        await app.resetAuthMethodSelection()

        XCTAssertEqual(service.resetLocalSessionCallCount, 1)
        XCTAssertEqual(service.startCallCount, 0, "A reset that failed must not restart the client")
        assertSessionKept(in: app)
        XCTAssertEqual(app.authManager.authState, .error("database in use"))
        XCTAssertEqual(app.errorPresenter.error, "database in use")
        XCTAssertFalse(app.authManager.isLoading)
    }

    func testCancelledStartupRetryKeepsSession() async {
        let service = MockTelegramService()
        service.retryStartupError = CancellationError()
        let app = makeApp(service: service)
        seedSession(in: app)

        await app.retry()

        XCTAssertEqual(service.retryStartupCallCount, 1)
        XCTAssertEqual(service.resetLocalSessionCallCount, 0, "A cancelled retry must not fall through to the reset")
        XCTAssertEqual(service.startCallCount, 0)
        assertSessionKept(in: app)
        XCTAssertFalse(app.authManager.isLoading)
    }

    func testFailedStartupRetryShowsTheErrorAndKeepsSession() async {
        let service = MockTelegramService()
        service.retryStartupError = TestError.failed(startupMessage)
        let app = makeApp(service: service)
        seedSession(in: app)

        await app.resetAuthMethodSelection()

        XCTAssertEqual(service.resetLocalSessionCallCount, 0)
        assertSessionKept(in: app)
        XCTAssertEqual(app.authManager.authState, .error(startupMessage))
        XCTAssertEqual(app.errorPresenter.error, startupMessage)
        XCTAssertFalse(app.authManager.isLoading)
    }

    // MARK: - Helpers

    private func seedSession(in app: AppState) {
        app.chatRepository.chats = [ChatInfo(id: chatId, title: "Old session", lastMessage: nil,
                                             unreadCount: 0, isGroup: false, isMuted: false, order: 1)]
        app.chatRepository.folderFilterEnabled = true
        app.chatRepository.selectedFolderId = 7
        app.chatRepository.draftStore.setDraft(chatId: chatId, text: "Old draft")
        // In memory only: the item must never reach the persisted queue.
        app.messageManager.messageQueue.pendingMessages = [.init(
            id: UUID(), chatId: chatId, text: "Old queued message", replyToMessageId: nil, createdAt: .distantPast
        )]
    }

    private func assertSessionKept(in app: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.chatRepository.chats.map(\.id), [chatId], file: file, line: line)
        XCTAssertEqual(app.chatRepository.draftStore.getDraft(chatId: chatId), "Old draft", file: file, line: line)
        XCTAssertEqual(app.messageManager.messageQueue.pendingMessages.map(\.text), ["Old queued message"],
                       file: file, line: line)
        XCTAssertTrue(app.chatRepository.folderFilterEnabled, file: file, line: line)
        XCTAssertEqual(app.chatRepository.selectedFolderId, 7, file: file, line: line)
    }

    private func assertSessionCleared(in app: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.chatRepository.chats.isEmpty, file: file, line: line)
        XCTAssertNil(app.chatRepository.draftStore.getDraft(chatId: chatId), file: file, line: line)
        XCTAssertFalse(app.messageManager.messageQueue.hasPending, file: file, line: line)
        XCTAssertFalse(app.chatRepository.folderFilterEnabled, file: file, line: line)
        XCTAssertEqual(app.chatRepository.selectedFolderId, 0, file: file, line: line)
    }

    /// Fails the test when the state never arrives, so a late event under a
    /// loaded runner is a failure with a reason and not a silent pass.
    private func waitUntil(
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "The expected state never arrived", file: file, line: line)
    }

    private func makeApp(service: MockTelegramService) -> AppState {
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        apps.append(app)
        return app
    }
}
