import Foundation
import XCTest
@testable import OrbitextWatch

/// Regression assertions. All requests are answered by MockTelegramService.
private actor FeatureAuditReadGate {
    private(set) var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocked = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Main-actor isolated like the mock it wraps: tests swap the gates on the
/// main actor while requests are in flight.
@MainActor
private final class FeatureAuditGatedService: ForwardingTelegramService {
    var readGate = FeatureAuditReadGate()
    var propertyGate: FeatureAuditReadGate?
    var olderMessagesGate: FeatureAuditReadGate?

    override func markAsRead(chatId: Int64, messageId: Int64) async throws {
        await readGate.pause()
        try await mock.markAsRead(chatId: chatId, messageId: messageId)
    }

    override func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] {
        let response = try await mock.getMessages(chatId: chatId, fromMessageId: fromMessageId, limit: limit)
        if fromMessageId != 0, let olderMessagesGate { await olderMessagesGate.pause() }
        return response
    }

    override func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties {
        let response = try await mock.getMessageProperties(chatId: chatId, messageId: messageId)
        if let propertyGate { await propertyGate.pause() }
        return response
    }
}

@MainActor
final class FeatureAuditTests: XCTestCase {
    private var repository: ChatRepository!
    private var store: ChatMessageStore!
    private var temporaryDirectory: URL!

    private func makeStore(service: any TelegramServiceProtocol) throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatureAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        repository = ChatRepository(
            service: service,
            draftStore: DraftStore(fileURL: temporaryDirectory.appendingPathComponent("drafts.json")),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        repository.chats = []
        repository.isInitialSyncComplete = false
        let manager = MessageManager(service: service, messageQueue: MessageQueue(fileURL: temporaryDirectory.appendingPathComponent("queue.json")))
        store = ChatMessageStore(messageManager: manager, chatRepository: repository)
    }

    override func tearDown() async throws {
        repository?.resetLoadedState()
        store = nil
        repository = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    func testMessagePropertiesAreIsolatedByChat() async throws {
        let service = MockTelegramService()
        try makeStore(service: service)
        var firstChatProperties = MessageProperties.default
        firstChatProperties.isResolved = true
        firstChatProperties.canBeEdited = true
        firstChatProperties.canBeDeletedForAllUsers = true
        service.defaultMessageProperties = firstChatProperties
        let first = await store.fetchMessageProperties(chatId: 100, messageId: 42)
        XCTAssertEqual(first, firstChatProperties)

        var secondChatProperties = MessageProperties.default
        secondChatProperties.isResolved = true
        secondChatProperties.canBeEdited = false
        secondChatProperties.canBeDeletedForAllUsers = false
        secondChatProperties.canBeForwarded = false
        service.defaultMessageProperties = secondChatProperties
        let second = await store.fetchMessageProperties(chatId: 200, messageId: 42)

        XCTAssertEqual(service.getMessagePropertiesCalls.map(\.chatId), [100, 200], "A distinct chat must fetch its own rights even when its message ID matches.")
        XCTAssertEqual(second, secondChatProperties, "Chat 200 must not inherit chat 100 edit/delete/forward rights.")
    }

    func testLiveMessageSurvivesInitialHistoryReadReceiptAwait() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        let initial = (1...5).map { message(id: Int64($0), chatId: 5) }
        service.mock.messagesByChatId[5] = initial
        let loading = Task { await store.loadInitialMessages(chatId: 5) }
        for _ in 0..<100 {
            if await service.readGate.isBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let blocked = await service.readGate.isBlocked
        XCTAssertTrue(blocked, "Harness must stop after history fetch and before initial load applies it.")
        guard blocked else { loading.cancel()
        return
        }

        let liveMessage = message(id: 6, chatId: 5)
        service.mock.messagesByChatId[5]?.append(liveMessage)
        store.handleIncomingMessage(liveMessage)
        XCTAssertEqual(store.messages(for: 5).map(\.id), [6], "Live event has reached the actual store.")
        await service.readGate.release()
        _ = await loading.value

        XCTAssertEqual(store.messages(for: 5).map(\.id), [1, 2, 3, 4, 5, 6], "Completing the older history snapshot must preserve the later live message.")
    }

    func testInitialHistoryPreservesDeletesEditsAndReactionsReceivedDuringLoad() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        let loading = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(service.readGate)

        store.handleDeleteMessages(chatId: 5, messageIds: [2])
        store.updateMessage(chatId: 5, messageId: 3) { $0.content = .text("Edited while loading") }
        let reactions = [ReactionInfo(emoji: "👍", count: 1, isSelected: false)]
        store.handleReactionsUpdate(chatId: 5, messageId: 4, reactions: reactions)
        await service.readGate.release()
        let result = await loading.value

        XCTAssertEqual(result.messages.map(\.id), [1, 3, 4, 5])
        XCTAssertEqual(store.messages(for: 5).first(where: { $0.id == 3 })?.content, .text("Edited while loading"))
        XCTAssertEqual(store.messages(for: 5).first(where: { $0.id == 4 })?.reactions, reactions)
    }

    func testResetDiscardsInitialHistoryAndItsPendingMutations() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        let loading = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(service.readGate)
        store.handleIncomingMessage(message(id: 6, chatId: 5))
        store.reset(chatId: 5)
        await service.readGate.release()
        let result = await loading.value

        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertNil(result.scrollToViewID)
        XCTAssertTrue(store.messages(for: 5).isEmpty)
        XCTAssertFalse(store.isLoading(chatId: 5))
    }

    func testReleaseDiscardsInitialHistoryAndLeavesNoEntryBehind() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        let loading = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(service.readGate)
        store.release(chatId: 5)
        await service.readGate.release()
        let result = await loading.value

        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertTrue(store.messages(for: 5).isEmpty)
        XCTAssertFalse(store.isLoading(chatId: 5))
        store.handleIncomingMessage(message(id: 6, chatId: 5))
        XCTAssertTrue(store.messages(for: 5).isEmpty, "A released chat takes no live messages")
    }

    func testCancelledInitialHistoryDoesNotReplayOverLiveState() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        let loading = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(service.readGate)
        store.handleIncomingMessage(message(id: 6, chatId: 5))
        loading.cancel()
        await service.readGate.release()
        _ = await loading.value

        XCTAssertEqual(store.messages(for: 5).map(\.id), [6])
        XCTAssertFalse(store.isLoading(chatId: 5))
    }

    func testResetOldCompletionDoesNotClearNewInitialLoadState() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        let oldGate = service.readGate
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        let oldLoad = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(oldGate)
        store.reset(chatId: 5)

        let newGate = FeatureAuditReadGate()
        service.readGate = newGate
        service.mock.messagesByChatId[5] = (10...14).map { message(id: Int64($0), chatId: 5) }
        let newLoad = Task { await store.loadInitialMessages(chatId: 5) }
        await waitUntilBlocked(newGate)
        await oldGate.release()
        _ = await oldLoad.value
        XCTAssertTrue(store.isLoading(chatId: 5), "An invalidated load cannot clear its successor's loading flag.")
        await newGate.release()
        _ = await newLoad.value
        XCTAssertEqual(store.messages(for: 5).map(\.id), [10, 11, 12, 13, 14])
        XCTAssertFalse(store.isLoading(chatId: 5))
    }

    func testPropertyInvalidationRejectsOldResponseWithoutErasingNewResult() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        let gate = FeatureAuditReadGate()
        service.propertyGate = gate
        var old = MessageProperties.default
        old.isResolved = true
        old.canBeEdited = true
        service.mock.defaultMessageProperties = old
        let first = Task { await store.fetchMessageProperties(chatId: 5, messageId: 1) }
        await waitUntilBlocked(gate)

        store.invalidateMessageProperties(chatId: 5, messageId: 1)
        service.propertyGate = nil
        var current = old
        current.canBeEdited = false
        service.mock.defaultMessageProperties = current
        let refreshed = await store.fetchMessageProperties(chatId: 5, messageId: 1)
        await gate.release()
        _ = await first.value

        XCTAssertEqual(refreshed, current)
        XCTAssertEqual(store.cachedProperties(chatId: 5, messageId: 1), current)
        XCTAssertEqual(service.mock.getMessagePropertiesCalls.count, 2)
    }

    func testConcurrentPropertyFetchesShareTheSameResponse() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        let gate = FeatureAuditReadGate()
        service.propertyGate = gate
        var expected = MessageProperties.default
        expected.isResolved = true
        expected.canBeEdited = true
        service.mock.defaultMessageProperties = expected
        let first = Task { await store.fetchMessageProperties(chatId: 5, messageId: 1) }
        await waitUntilBlocked(gate)
        let second = Task { await store.fetchMessageProperties(chatId: 5, messageId: 1) }
        for _ in 0..<20 { await Task.yield() }
        await gate.release()
        let firstValue = await first.value
        let secondValue = await second.value

        XCTAssertEqual(firstValue, expected)
        XCTAssertEqual(secondValue, expected)
        XCTAssertEqual(service.mock.getMessagePropertiesCalls.count, 1)
    }

    func testResetCancelsPropertyFetchAndPreservesOtherChatCache() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        var expected = MessageProperties.default
        expected.isResolved = true
        service.mock.defaultMessageProperties = expected
        _ = await store.fetchMessageProperties(chatId: 200, messageId: 42)
        let gate = FeatureAuditReadGate()
        service.propertyGate = gate
        let loading = Task { await store.fetchMessageProperties(chatId: 100, messageId: 42) }
        await waitUntilBlocked(gate)
        store.reset(chatId: 100)
        await gate.release()
        let result = await loading.value

        XCTAssertEqual(result, .default)
        XCTAssertNil(store.cachedProperties(chatId: 100, messageId: 42))
        XCTAssertEqual(store.cachedProperties(chatId: 200, messageId: 42), expected)
    }

    func testResetAllClearsSessionAndRejectsLateHistoryAndProperties() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...5).map { message(id: Int64($0), chatId: 5) }
        store.handleIncomingMessage(message(id: 1, chatId: 200))
        store.setActiveChat(5)
        let propertyGate = FeatureAuditReadGate()
        service.propertyGate = propertyGate
        let history = Task { await store.loadInitialMessages(chatId: 5) }
        let properties = Task { await store.fetchMessageProperties(chatId: 200, messageId: 1) }
        await waitUntilBlocked(service.readGate)
        await waitUntilBlocked(propertyGate)
        store.resetAll()
        await service.readGate.release()
        await propertyGate.release()
        _ = await history.value
        _ = await properties.value

        XCTAssertNil(store.activeChatId)
        XCTAssertTrue(store.messages(for: 5).isEmpty)
        XCTAssertTrue(store.messages(for: 200).isEmpty)
        XCTAssertFalse(store.isLoading(chatId: 5))
        XCTAssertNil(store.cachedProperties(chatId: 200, messageId: 1))
    }

    func testOlderHistoryPreservesLiveChangesAndRejectsCompletionAfterReset() async throws {
        let service = FeatureAuditGatedService()
        try makeStore(service: service)
        service.mock.messagesByChatId[5] = (1...10).map { message(id: Int64($0), chatId: 5) }
        store.reset(chatId: 5)
        store.handleIncomingMessage(message(id: 10, chatId: 5))
        let gate = FeatureAuditReadGate()
        service.olderMessagesGate = gate
        let olderLoad = Task { await store.loadOlderMessages(chatId: 5) }
        await waitUntilBlocked(gate)

        // These rows exist in the suspended response, but not in the visible
        // store yet. The load must replay their newer server/UI mutations.
        store.handleDeleteMessages(chatId: 5, messageIds: [2])
        store.updateMessage(chatId: 5, messageId: 3) { $0.content = .text("Edited older message") }
        await gate.release()
        await olderLoad.value
        XCTAssertEqual(store.messages(for: 5).map(\.id), [1, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(store.messages(for: 5).first(where: { $0.id == 3 })?.content, .text("Edited older message"))
        XCTAssertFalse(store.isLoadingOlder(chatId: 5))

        // An independent chat is reset while its older page is in flight.
        // Its obsolete response must not restore rows after navigation away.
        service.mock.messagesByChatId[6] = (1...10).map { message(id: Int64($0), chatId: 6) }
        store.reset(chatId: 6)
        store.handleIncomingMessage(message(id: 10, chatId: 6))
        let resetGate = FeatureAuditReadGate()
        service.olderMessagesGate = resetGate
        let resetLoad = Task { await store.loadOlderMessages(chatId: 6) }
        await waitUntilBlocked(resetGate)
        store.reset(chatId: 6)
        await resetGate.release()
        await resetLoad.value
        XCTAssertTrue(store.messages(for: 6).isEmpty)
        XCTAssertFalse(store.isLoadingOlder(chatId: 6))
    }

    private func waitUntilBlocked(_ gate: FeatureAuditReadGate) async {
        for _ in 0..<100 {
            if await gate.isBlocked { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Harness did not reach its deterministic gate")
    }

    private func message(id: Int64, chatId: Int64) -> MessageInfo {
        MessageInfo(id: id, chatId: chatId, senderName: "Audit Sender", senderId: 7, content: .text(FormattedString(text: "Message \(id)")), date: Date(timeIntervalSince1970: TimeInterval(id)), isOutgoing: false, isRead: false)
    }
}
