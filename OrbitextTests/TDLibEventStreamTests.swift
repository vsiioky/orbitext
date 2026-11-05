import Darwin
import XCTest
@testable import OrbitextWatch

/// The transport has one event stream for the life of the process. A burst
/// the main actor cannot keep up with, such as the cold-start sync of the
/// chat list, queues in the stream's buffer, and the standard library's deque
/// keeps the capacity of its largest burst after the consumer has caught up.
/// Every slot of that buffer is as wide as one event.
final class TDLibEventStreamTests: XCTestCase {
    /// An event held its largest payload inline, a ChatInfo with its last
    /// message: 536 bytes a slot.
    func testAnEventTakesAPointerInTheStreamBuffer() {
        XCTAssertLessThanOrEqual(MemoryLayout<TDLibEvent>.stride, 16)
    }

    /// The burst of a cold start on an account with about 1,100 chats queued
    /// some 4,000 events and left 2.3 MB of empty buffer behind.
    func testDrainedBurstLeavesLittleOfItsBufferBehind() async {
        let events = (0..<Self.burst).map { TDLibEvent.chatUpdated(Self.chat($0)) }
        var retained: [Int] = []
        // Other threads of the host allocate too; they can only add to a
        // measurement, so the smallest of a few is the stream's own.
        for _ in 0..<3 {
            let before = Self.bytesInUse()
            let (stream, continuation) = AsyncStream<TDLibEvent>.makeStream()
            for event in events {
                continuation.yield(event)
            }
            var iterator = stream.makeAsyncIterator()
            for _ in 0..<Self.burst {
                _ = await iterator.next()
            }
            retained.append(Self.bytesInUse() - before)
            withExtendedLifetime(continuation) {}
        }

        XCTAssertLessThan(retained.min() ?? .max, 256 * 1024, "Bytes left after the drain: \(retained)")
    }

    // MARK: - Helpers

    private static let burst = 4000

    private static func bytesInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    private static func chat(_ index: Int) -> ChatInfo {
        let message = MessageInfo(
            id: Int64(index), chatId: Int64(index), senderName: "Sender \(index)", senderId: 2,
            content: .text(FormattedString(text: "Last message \(index)")),
            date: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: false, isRead: false
        )
        return ChatInfo(
            id: Int64(index), title: "Chat \(index)", lastMessage: message, unreadCount: 0,
            isGroup: false, isMuted: false, order: Int64(index)
        )
    }
}
