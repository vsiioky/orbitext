import XCTest
@testable import OrbitextWatch

final class MessageQueueTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    func testEnqueueAndDequeue() {
        let queue = makeQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "Hello", replyToMessageId: 42)
        XCTAssertEqual(queue.pendingMessages.count, 1)
        XCTAssertTrue(queue.hasPending)
        XCTAssertEqual(queue.pendingMessages.first?.replyToMessageId, 42)

        let id = queue.pendingMessages.first!.id
        queue.dequeue(id)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertFalse(queue.hasPending)
    }

    func testIncrementRetry() {
        let queue = makeQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "Test")
        let id = queue.pendingMessages.first!.id
        XCTAssertEqual(queue.pendingMessages.first!.retryCount, 0)

        queue.incrementRetry(id)
        XCTAssertEqual(queue.pendingMessages.first!.retryCount, 1)

        queue.incrementRetry(id)
        XCTAssertEqual(queue.pendingMessages.first!.retryCount, 2)
    }

    func testMaxRetriesSeparation() {
        let queue = makeQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "Will fail")
        let id = queue.pendingMessages.first!.id

        for _ in 0..<AppConstants.Queue.maxRetries {
            queue.incrementRetry(id)
        }

        XCTAssertTrue(queue.sendableMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)
    }

    func testPendingForChatId() {
        let queue = makeQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "A")
        queue.enqueue(chatId: 2, text: "B")
        queue.enqueue(chatId: 1, text: "C")

        XCTAssertEqual(queue.pendingFor(chatId: 1).count, 2)
        XCTAssertEqual(queue.pendingFor(chatId: 2).count, 1)
        XCTAssertEqual(queue.pendingFor(chatId: 3).count, 0)
    }

    func testClear() {
        let queue = makeQueue()
        queue.enqueue(chatId: 1, text: "Test")
        queue.clear()
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testCorruptStoreIsPreservedBeforeNewWrites() throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("pending_messages.json")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: fileURL)

        let queue = MessageQueue(fileURL: fileURL)

        XCTAssertTrue(queue.pendingMessages.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pending_messages.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        queue.enqueue(chatId: 42, text: "after corruption")

        XCTAssertEqual(queue.pendingMessages.map(\.text), ["after corruption"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
    }

    func testLoadsExistingQueueAndPreservesMessageMetadataOnWrite() throws {
        let fileURL = makeTempDir().appendingPathComponent("pending_messages.json")
        let id = UUID(uuidString: "AF4628AD-4068-4C83-BAFA-FE5BEB8111A5")!
        let fixture = Data(#"[{"id":"AF4628AD-4068-4C83-BAFA-FE5BEB8111A5","chatId":-100123,"text":"Queued offline","replyToMessageId":42,"createdAt":12345,"retryCount":2}]"#.utf8)
        try fixture.write(to: fileURL)

        let queue = MessageQueue(fileURL: fileURL)
        let pending = try XCTUnwrap(queue.pendingMessages.first)
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.chatId, -100123)
        XCTAssertEqual(pending.text, "Queued offline")
        XCTAssertEqual(pending.replyToMessageId, 42)
        XCTAssertEqual(pending.createdAt, Date(timeIntervalSinceReferenceDate: 12345))
        XCTAssertEqual(pending.retryCount, 2)

        queue.incrementRetry(id)

        let reloaded = try XCTUnwrap(MessageQueue(fileURL: fileURL).pendingMessages.first)
        XCTAssertEqual(reloaded.id, pending.id)
        XCTAssertEqual(reloaded.chatId, pending.chatId)
        XCTAssertEqual(reloaded.text, pending.text)
        XCTAssertEqual(reloaded.replyToMessageId, pending.replyToMessageId)
        XCTAssertEqual(reloaded.createdAt, pending.createdAt)
        XCTAssertEqual(reloaded.retryCount, 3)
    }

    func testFirstWriteCreatesNestedDirectoryAndClearPersistsEmptyQueue() {
        let fileURL = makeTempDir().appendingPathComponent("nested/store/pending_messages.json")
        let queue = MessageQueue(fileURL: fileURL)
        XCTAssertFalse(queue.hasPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        queue.enqueue(chatId: 42, text: "Queued")
        XCTAssertEqual(MessageQueue(fileURL: fileURL).pendingMessages.map(\.text), ["Queued"])

        queue.clear()
        XCTAssertTrue(MessageQueue(fileURL: fileURL).pendingMessages.isEmpty)
    }

    func testReadFailureDoesNotMoveExistingDirectoryAsCorruptFile() throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("pending_messages.json", isDirectory: true)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        let queue = MessageQueue(fileURL: fileURL)

        XCTAssertTrue(queue.pendingMessages.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.map(\.lastPathComponent), ["pending_messages.json"])
    }

    func testFailedWriteKeepsPendingMessageAndExistingFile() throws {
        let blocker = makeTempDir().appendingPathComponent("not-a-directory")
        let original = Data("keep this file".utf8)
        try original.write(to: blocker)
        let queue = MessageQueue(fileURL: blocker.appendingPathComponent("pending_messages.json"))

        queue.enqueue(chatId: 42, text: "Still pending")

        XCTAssertEqual(queue.pendingMessages.map(\.text), ["Still pending"])
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    private func makeQueue() -> MessageQueue {
        MessageQueue(fileURL: makeTempDir().appendingPathComponent("pending_messages.json"))
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageQueueTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
