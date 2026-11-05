import XCTest
@testable import OrbitextWatch

final class MessageQueueRetryTests: XCTestCase {
    func testRetryFailedResetsRetryCount() {
        let queue = MessageQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "Will fail")
        let id = queue.pendingMessages.first!.id

        // Exhaust retries
        for _ in 0..<AppConstants.Queue.maxRetries {
            queue.incrementRetry(id)
        }
        XCTAssertTrue(queue.sendableMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)

        // Retry failed → resets to sendable
        queue.retryFailed(id)
        XCTAssertEqual(queue.pendingMessages.first!.retryCount, 0)
        XCTAssertEqual(queue.sendableMessages.count, 1)
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testRemoveFailedDeletesMessage() {
        let queue = MessageQueue()
        queue.clear()

        queue.enqueue(chatId: 1, text: "To remove")
        let id = queue.pendingMessages.first!.id

        for _ in 0..<AppConstants.Queue.maxRetries {
            queue.incrementRetry(id)
        }
        XCTAssertEqual(queue.failedMessages.count, 1)

        queue.removeFailed(id)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testPersistenceAcrossInstances() {
        let queue1 = MessageQueue()
        queue1.clear()
        queue1.enqueue(chatId: 99, text: "Persist me", replyToMessageId: 42)
        let id = queue1.pendingMessages.first!.id
        queue1.incrementRetry(id)

        // New instance should load from disk
        let queue2 = MessageQueue()
        XCTAssertEqual(queue2.pendingMessages.count, 1)
        XCTAssertEqual(queue2.pendingMessages.first?.text, "Persist me")
        XCTAssertEqual(queue2.pendingMessages.first?.replyToMessageId, 42)
        XCTAssertEqual(queue2.pendingMessages.first?.retryCount, 1)

        // Cleanup
        queue2.clear()
    }
}
