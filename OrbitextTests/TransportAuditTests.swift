import XCTest
@testable import OrbitextWatch

/// Regressions for composite message identity and extended flood backoff.
/// No live TDLib client starts.
final class TransportAuditTests: XCTestCase {
    func testReplyResolutionUsesChatAndMessageIdentity() async {
        let service = TDLibService()
        let originalA = message(id: 42, chatId: 101, sender: "Alice", text: "Original in A")
        let originalB = message(id: 42, chatId: 202, sender: "Bob", text: "Original in B")
        var replyB = message(id: 43, chatId: 202, sender: "Reply author", text: "Reply in B")
        replyB.replyToMessageId = 42
        replyB.replyToSenderResolved = false
        var messages = [originalA, originalB, replyB]

        await service.resolveMessageNames(&messages)

        XCTAssertEqual(messages[2].replyToSenderName, "Bob",
                       "A global-search reply must resolve its sender within its own chat")
        XCTAssertEqual(messages[2].replyToPreview?.text, "Original in B",
                       "A colliding message ID in another chat must not supply reply content")
    }

    func testForeignChatOriginalCannotResolveMissingReply() async {
        let service = TDLibService()
        let foreignOriginal = message(id: 42, chatId: 101, sender: "Alice", text: "Foreign preview")
        var reply = message(id: 43, chatId: 202, sender: "Bob", text: "Reply")
        reply.replyToMessageId = 42
        reply.replyToSenderResolved = false
        var messages = [foreignOriginal, reply]

        await service.resolveMessageNames(&messages)

        XCTAssertNil(messages[1].replyToPreview,
                     "Unavailable original in chat 202 must not borrow content from chat 101")
        XCTAssertFalse(messages[1].replyToSenderResolved,
                       "Unavailable original must remain unresolved")
    }

    func testExtendedFloodWaitRemainsInForceForAlreadyWaitingRequest() async throws {
        let throttle = TDRequestThrottle(minSpacing: .zero)
        await throttle.reportFloodWait(seconds: 1)
        let started = expectation(description: "request starts waiting on initial flood backoff")
        let waiter = Task {
            started.fulfill()
            try await throttle.acquireSlot()
            return ContinuousClock.now
        }
        defer { waiter.cancel() }
        await fulfillment(of: [started], timeout: 1)
        // Allow the actor to suspend inside the initial one-second sleep.
        try await Task.sleep(for: .milliseconds(200))
        let extendedAt = ContinuousClock.now
        await throttle.reportFloodWait(seconds: 3)

        let releasedAt = try await waiter.value

        XCTAssertGreaterThanOrEqual(releasedAt - extendedAt, .milliseconds(2800),
            "A request waiting on the old deadline must not clear the newer flood backoff")
    }

    private func message(id: Int64, chatId: Int64, sender: String, text: String) -> MessageInfo {
        MessageInfo(
            id: id,
            chatId: chatId,
            senderName: sender,
            senderId: 0,
            content: .text(FormattedString(text: text)),
            date: Date(timeIntervalSince1970: 0),
            isOutgoing: false,
            isRead: false,
            senderResolved: true
        )
    }
}
