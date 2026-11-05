import XCTest
@testable import OrbitextWatch

@MainActor
final class MessageManagerTests: XCTestCase {
    private var service: MockTelegramService!
    private var queue: MessageQueue!
    private var manager: MessageManager!
    private var errorPresenter: ErrorPresenter!

    override func setUp() async throws {
        service = MockTelegramService()
        queue = MessageQueue()
        queue.clear()
        manager = MessageManager(service: service, messageQueue: queue)
        errorPresenter = ErrorPresenter()
        manager.errorPresenter = errorPresenter
    }

    func testLoadMessagesReturnsResults() async {
        service.messagesByChatId[1] = [
            MessageInfo(id: 1, chatId: 1, senderName: "Alice", senderId: 2, content: .text("Hello"), date: Date(), isOutgoing: false, isRead: false)
        ]

        let messages = await manager.loadMessages(chatId: 1)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(service.getMessagesRequests.first?.chatId, 1)
    }

    func testSendMessageEnqueuesWhenTheClientIsNotRunning() async {
        service.sendMessageError = TelegramServiceError.notStarted

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping", replyToMessageId: 42)

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(queue.pendingMessages.count, 1)
        XCTAssertEqual(queue.pendingMessages.first?.text, "Ping")
        XCTAssertEqual(queue.pendingMessages.first?.replyToMessageId, 42)
        XCTAssertEqual(errorPresenter.error, "TDLib not started")
    }

    /// The mock throws the error type by hand; this is the real transport.
    func testNativeServiceWithoutAClientReportsAnErrorTheQueueRetries() async {
        let native = TDLibService(databaseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("not-started-\(UUID().uuidString)"))
        let nativeManager = MessageManager(service: native, messageQueue: queue)
        nativeManager.errorPresenter = errorPresenter

        let outcome = await nativeManager.sendMessage(chatId: 1, text: "Ping")

        XCTAssertEqual(outcome, .queued, "The transport's not-started error must reach the offline queue")
        XCTAssertEqual(queue.pendingMessages.map(\.text), ["Ping"])
    }

    func testRejectedMessageFailsInsteadOfQueueing() async {
        // TDLib queues messages itself while offline; an error from a running
        // client means the message was refused and a retry cannot help.
        service.sendMessageError = TDError.api(code: 403, message: "CHAT_WRITE_FORBIDDEN")

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping")

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(queue.pendingMessages.isEmpty, "A refused message would be retried forever")
        XCTAssertEqual(errorPresenter.error, "CHAT_WRITE_FORBIDDEN")
    }

    func testTimedOutMessageIsNotQueuedTwice() async {
        // TDLib may have accepted it before the response was lost.
        service.sendMessageError = TDError.timeout

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping")

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(queue.pendingMessages.isEmpty, "A queued copy could be sent a second time")
    }

    func testRateLimitedMessageIsQueued() async {
        service.sendMessageError = TDError.rateLimited(seconds: 600)

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping")

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(queue.pendingMessages.count, 1)
    }

    func testOnlyMessagesTDLibNeverReceivedAreRetryable() {
        let cases: [(Error, Bool)] = [
            (TelegramServiceError.notStarted, true),
            (TDError.clientClosed, true),
            (TDError.rateLimited(seconds: 60), true),
            (TDError.api(code: 420, message: "FLOOD_WAIT_5"), true),
            (TDError.api(code: 429, message: "Too Many Requests: retry after 7"), true),
            (TDError.requestAbandoned, false),
            (TDError.timeout, false),
            (TDError.api(code: 400, message: "Chat not found"), false),
            (TestError.failed("other"), false)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(MessageManager.isRetryableLater(error), expected, "\(error)")
        }
    }

    func testDrainKeepsRetryingWhileTheClientIsDown() async {
        queue.enqueue(chatId: 1, text: "Ping")
        service.sendMessageError = TelegramServiceError.notStarted

        await manager.flushMessageQueue()

        XCTAssertEqual(queue.sendableMessages.map(\.retryCount), [1])
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testUnreadableAnswerStillCountsAsSent() async {
        // TDLib answered with the pending message; only its parsing failed.
        service.sendMessageError = TDError.unexpectedResponse

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping")

        XCTAssertEqual(outcome, .sent, "A retry would send the message twice")
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testQueuedMessageWithUnreadableAnswerLeavesTheQueue() async {
        queue.enqueue(chatId: 1, text: "Ping")
        service.sendMessageError = TDError.unexpectedResponse

        await manager.flushMessageQueue()

        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testCancelledPrivateChatOpeningCancelsTheSend() async {
        service.createPrivateChatError = CancellationError()

        let outcome = await manager.sendMessage(chatId: 42, text: "Hi", opensPrivateChat: true)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(errorPresenter.error)
    }

    func testQueuedMessageRefusedOnRetryIsMarkedFailedAtOnce() async {
        queue.enqueue(chatId: 1, text: "Ping")
        service.sendMessageError = TDError.api(code: 400, message: "Chat not found")

        await manager.flushMessageQueue()

        XCTAssertEqual(queue.failedMessages.map(\.text), ["Ping"],
                       "A refused message kept being retried until maxRetries")
        XCTAssertTrue(queue.sendableMessages.isEmpty)
    }

    func testMessageToContactOpensThePrivateChatFirst() async {
        let outcome = await manager.sendMessage(chatId: 42, text: "Hi", opensPrivateChat: true)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(service.createdPrivateChatUserIds, [42],
                       "TDLib answers Chat not found until the private chat exists")
        XCTAssertEqual(service.sentMessages.map(\.chatId), [42])
    }

    func testMessageToContactIsNotQueuedWhenThePrivateChatCannotBeOpened() async {
        service.createPrivateChatError = TelegramServiceError.notStarted

        let outcome = await manager.sendMessage(chatId: 42, text: "Hi", opensPrivateChat: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(service.sentMessages.isEmpty)
        XCTAssertTrue(queue.pendingMessages.isEmpty, "The queue would later send to a chat that does not exist")
    }

    func testSendMessageReturnsSentOnSuccess() async {
        let outcome = await manager.sendMessage(chatId: 1, text: "Ping", replyToMessageId: 42)

        XCTAssertEqual(outcome, .sent)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(service.sentMessages.first?.text, "Ping")
        XCTAssertEqual(service.sentMessages.first?.replyToMessageId, 42)
    }

    func testSendMessageDoesNotEnqueueOnCancellation() async {
        service.sendMessageError = CancellationError()

        let outcome = await manager.sendMessage(chatId: 1, text: "Ping", replyToMessageId: 42)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertNil(errorPresenter.error)
    }

    func testSendVoiceReturnsFalseOnFailure() async {
        service.sendVoiceError = TestError.failed("Voice failed")

        let sent = await manager.sendVoice(chatId: 1, data: Data([1, 2, 3]), duration: 4)

        XCTAssertFalse(sent)
        XCTAssertTrue(service.sentVoices.isEmpty)
        XCTAssertEqual(errorPresenter.error, "Voice failed")
    }

    func testSendVoiceReturnsTrueOnSuccess() async {
        let sent = await manager.sendVoice(chatId: 1, data: Data([1, 2, 3]), duration: 4)

        XCTAssertTrue(sent)
        XCTAssertEqual(service.sentVoices.first?.chatId, 1)
        XCTAssertEqual(service.sentVoices.first?.duration, 4)
    }

    func testSearchMessagesReturnsResults() async {
        service.searchResults = [
            MessageInfo(id: 11, chatId: 7, senderName: "Bob", senderId: 3, content: .text("needle"), date: Date(), isOutgoing: false, isRead: true)
        ]

        let results = await manager.searchMessages(query: "needle")

        XCTAssertEqual(results.map(\.id), [11])
        XCTAssertEqual(service.searchQueries.first?.query, "needle")
    }

    func testRestoredContactsCarryNoFileIdOfTheRunThatSavedThem() {
        // TDLib numbers files per instance: in this run the saved id can name
        // another file, or none yet.
        let file = ListCache<ContactInfo>(filename: "cached_contacts.json")
        let prior = file.load()
        defer {
            if let prior { file.save(prior) } else { file.clear() }
            file.flush()
        }
        var contact = ContactInfo(id: 42, firstName: "Alice", lastName: "", phone: "", username: "alice", isOnline: false)
        contact.photoFileId = "4242"
        file.save([contact])
        file.flush()

        let restored = MessageManager(service: service, messageQueue: queue)

        XCTAssertEqual(restored.cachedContacts?.map(\.id), [42])
        XCTAssertNil(restored.cachedContacts?.first?.photoFileId)
    }

    func testFlushMessageQueueClearsOnSuccess() async {
        queue.enqueue(chatId: 1, text: "Queued", replyToMessageId: 42)

        await manager.flushMessageQueue()

        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(service.sentMessages.first?.text, "Queued")
        XCTAssertEqual(service.sentMessages.first?.replyToMessageId, 42)
    }

    func testFlushMessageQueueStopsAfterCancellation() async {
        queue.enqueue(chatId: 1, text: "First")
        queue.enqueue(chatId: 1, text: "Second")

        let flushTask = Task { await manager.flushMessageQueue() }
        for _ in 0..<100 where service.sentMessages.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.sentMessages.map(\.text), ["First"])

        flushTask.cancel()
        await flushTask.value

        XCTAssertEqual(service.sentMessages.map(\.text), ["First"])
        XCTAssertEqual(queue.pendingMessages.map(\.text), ["Second"])
        XCTAssertEqual(queue.pendingMessages.first?.retryCount, 0)
    }

    func testDeleteMessageReturnsTrueOnSuccess() async {
        let deleted = await manager.deleteMessage(chatId: 1, messageId: 2)

        XCTAssertTrue(deleted)
        XCTAssertEqual(service.deletedMessages.count, 1)
        XCTAssertEqual(service.deletedMessages.first?.chatId, 1)
        XCTAssertEqual(service.deletedMessages.first?.messageId, 2)
    }

    func testDeleteMessageReturnsFalseOnFailure() async {
        service.deleteMessageError = TestError.failed("Delete failed")

        let deleted = await manager.deleteMessage(chatId: 1, messageId: 2)

        XCTAssertFalse(deleted)
        XCTAssertTrue(service.deletedMessages.isEmpty)
        XCTAssertEqual(errorPresenter.error, "Delete failed")
    }

    func testSetReactionReturnsTrueOnSuccess() async {
        let didSet = await manager.setReaction(chatId: 1, messageId: 2, emoji: "👍")

        XCTAssertTrue(didSet)
    }

    func testSetReactionReturnsFalseOnFailure() async {
        service.reactionError = TestError.failed("Reaction failed")

        let didSet = await manager.setReaction(chatId: 1, messageId: 2, emoji: "👍")

        XCTAssertFalse(didSet)
        XCTAssertEqual(errorPresenter.error, "Reaction failed")
    }

    func testSetReactionReturnsFalseWithoutErrorOnCancellation() async {
        service.reactionError = CancellationError()

        let didSet = await manager.setReaction(chatId: 1, messageId: 2, emoji: "👍")

        XCTAssertFalse(didSet)
        XCTAssertNil(errorPresenter.error)
    }

    func testRemoveReactionReturnsTrueOnSuccess() async {
        let didRemove = await manager.removeReaction(chatId: 1, messageId: 2, emoji: "👍")

        XCTAssertTrue(didRemove)
    }

    func testRemoveReactionReturnsFalseOnFailure() async {
        service.reactionError = TestError.failed("Remove failed")

        let didRemove = await manager.removeReaction(chatId: 1, messageId: 2, emoji: "👍")

        XCTAssertFalse(didRemove)
        XCTAssertEqual(errorPresenter.error, "Remove failed")
    }
}
