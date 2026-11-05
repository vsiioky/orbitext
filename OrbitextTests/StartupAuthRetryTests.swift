import Security
import XCTest
@testable import OrbitextWatch

@MainActor
final class StartupAuthRetryTests: XCTestCase {
    func testAuthScreenRetryPreservesDatabaseKeyAndCachedSessionOnRepeatedKeychainFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        await fixture.start()

        for retryIndex in 1...2 {
            await fixture.app.resetAuthMethodSelection()
            await fixture.waitForStates(1 + retryIndex * 2)

            XCTAssertEqual(fixture.states, [.error(fixture.message)] +
                Array(repeating: [AuthState.idle, .error(fixture.message)], count: retryIndex).flatMap(\.self))
            XCTAssertEqual(fixture.probe.resolveCount, retryIndex + 1)
            try fixture.assertSessionPreserved()
            XCTAssertFalse(fixture.app.authManager.isLoading)
        }
    }

    func testAppRetryPreservesDatabaseInsteadOfForcingLocalLogout() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        await fixture.start()

        await fixture.app.retry()
        await fixture.waitForStates(3)

        XCTAssertEqual(fixture.states, [.error(fixture.message), .idle, .error(fixture.message)])
        XCTAssertEqual(fixture.probe.resolveCount, 2)
        XCTAssertFalse(fixture.app.authManager.isLoading)
        try fixture.assertSessionPreserved()
    }

    func testConcurrentRetryDoesNotQueueASecondAuthorizationReset() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        await fixture.start()
        let lease = try await fixture.service.session.lifecycleGate.acquire()
        let first = Task { await fixture.app.retry() }
        await fixture.waitUntil { fixture.app.authManager.isLoading }
        XCTAssertTrue(fixture.app.authManager.isLoading)

        // This call must return while the first retry is waiting for the lease.
        // Otherwise a duplicate tap could reset a newly recovered session.
        var secondReturned = false
        let second = Task {
            await fixture.app.resetAuthMethodSelection()
            secondReturned = true
        }
        await fixture.waitUntil { secondReturned }
        let ignoredWhileFirstWasPending = secondReturned
        lease.release()
        await first.value
        await second.value
        await fixture.waitForStates(3)

        XCTAssertTrue(ignoredWhileFirstWasPending)
        XCTAssertEqual(fixture.probe.resolveCount, 2)
        XCTAssertEqual(fixture.states, [.error(fixture.message), .idle, .error(fixture.message)])
        XCTAssertFalse(fixture.app.authManager.isLoading)
        try fixture.assertSessionPreserved()
    }

    func testCancelledStartupRetryPreservesTheFailureAndSession() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        await fixture.start()
        let lease = try await fixture.service.session.lifecycleGate.acquire()
        let retry = Task { await fixture.app.resetAuthMethodSelection() }
        await fixture.waitUntil { fixture.app.authManager.isLoading }
        retry.cancel()
        lease.release()
        await retry.value

        XCTAssertEqual(fixture.probe.resolveCount, 1)
        XCTAssertEqual(fixture.app.authManager.authState, .error(fixture.message))
        XCTAssertFalse(fixture.app.authManager.isLoading)
        try fixture.assertSessionPreserved()
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var resolves = 0
        private var removals = 0
        var resolveCount: Int { lock.withLock { resolves } }
        var removeCount: Int { lock.withLock { removals } }
        func resolve() throws -> (key: Data, needsMigration: Bool) {
            lock.withLock { resolves += 1 }
            throw TDLibDatabaseKey.KeychainError.status(errSecInteractionNotAllowed)
        }
        func remove() { lock.withLock { removals += 1 } }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let sentinel: URL
        let sentinelData = Data("existing encrypted database".utf8)
        let probe = Probe()
        let service: TDLibService
        let app: AppState
        let message = TDLibDatabaseKey.KeychainError.status(errSecInteractionNotAllowed).localizedDescription
        var states: [AuthState] = []
        private let chatId: Int64 = 9_876_543
        private var draft: String?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sentinel = directory.appendingPathComponent("td.binlog")
            try sentinelData.write(to: sentinel)
            let probe = probe
            service = TDLibService(
                databaseDirectory: directory,
                apiCredentials: (id: 1, hash: "offline-test"),
                resolveDatabaseKey: { _ in try probe.resolve() },
                removeDatabaseKey: { probe.remove() }
            )
            app = AppState(
                service: service,
                notificationManager: MockNotificationManager(),
                widgetSync: MockWidgetSync(),
                preferences: AppPreferencesStore(defaults: makeTestDefaults())
            )
            app.isInitialized = true
            app.chatRepository.chats = [ChatInfo(id: chatId, title: "Cached chat", lastMessage: nil,
                                                unreadCount: 0, isGroup: false, isMuted: false, order: 1)]
            app.chatRepository.folderFilterEnabled = true
            app.chatRepository.selectedFolderId = 7
            draft = app.chatRepository.draftStore.getDraft(chatId: chatId)
            app.chatRepository.draftStore.setDraft(chatId: chatId, text: "Unsent draft")
            // Keep the synthetic outbound item in memory; never persist or send it.
            app.messageManager.messageQueue.pendingMessages = [.init(
                id: UUID(), chatId: chatId, text: "Unsent test item", replyToMessageId: nil, createdAt: .distantPast
            )]
            app.chatMessageStore.setActiveChat(chatId)
            app.eventTask = Task { [weak self, service] in
                for await event in service.events {
                    guard let self, !Task.isCancelled else { return }
                    if case .authStateChanged(let state) = event { self.states.append(state) }
                    self.app.handleEvent(event)
                }
            }
        }

        func start() async {
            await service.start()
            await waitForStates(1)
            XCTAssertEqual(states, [.error(message)])
            XCTAssertNil(service.getTD(), "Keychain failure must stop before native client creation")
        }

        func assertSessionPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData, file: file, line: line)
            XCTAssertEqual(probe.removeCount, 0, "Retry must not remove the encryption key", file: file, line: line)
            XCTAssertEqual(app.chatRepository.chats.map(\.id), [chatId], file: file, line: line)
            XCTAssertEqual(app.chatRepository.draftStore.getDraft(chatId: chatId), "Unsent draft", file: file, line: line)
            XCTAssertEqual(app.messageManager.messageQueue.pendingMessages.map(\.text), ["Unsent test item"], file: file, line: line)
            XCTAssertEqual(app.chatMessageStore.activeChatId, chatId, file: file, line: line)
            XCTAssertTrue(app.chatRepository.folderFilterEnabled, file: file, line: line)
            XCTAssertEqual(app.chatRepository.selectedFolderId, 7, file: file, line: line)
            XCTAssertNil(service.getTD(), file: file, line: line)
        }

        func waitForStates(_ count: Int) async { await waitUntil { states.count >= count } }

        func waitUntil(_ predicate: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(1)
            while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        }

        func finish() {
            app.eventTask?.cancel()
            service.session.finishEventsForTesting()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
            app.chatRepository.draftStore.setDraft(chatId: chatId, text: draft)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
