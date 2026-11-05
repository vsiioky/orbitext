import XCTest
@testable import OrbitextWatch

/// How loading the chat list uses TDLib: every request is counted, throttled
/// and awaited, and a cache miss cannot flood TDLib with local reads.
final class TDChatListPolicyTests: XCTestCase {
    func testLoadChatsIsCountedByTelemetryLikeEveryOtherRequest() async throws {
        XCTAssertTrue(AppLogSettings.tdTelemetryEnabled, "Telemetry is on in test builds")
        let telemetry = TDRequestTelemetry(ringCapacity: 100, burstThreshold: 100, burstWindow: 60)
        let fixture = ScriptedServiceFixture(script: Self.emptyPages())
        fixture.client.telemetry = telemetry
        defer { fixture.finish() }

        _ = try await fixture.service.getChats(limit: 10)

        let loads = await telemetry.countFor(method: "loadChats")
        let reads = await telemetry.countFor(method: "getChats")
        XCTAssertEqual(loads, 1, "loadChats went out without the telemetry the trace export relies on")
        XCTAssertEqual(reads, 2)
    }

    func testPageIsCompleteOnlyWhenEveryListedChatBecameARow() async throws {
        let fixture = ScriptedServiceFixture { request in
            switch request["@type"] as? String {
            case "getChats": return .result(["@type": "chats", "chat_ids": [1, 2, 3]])
            default: return .error(code: 400, message: "Chat not found")
            }
        }
        defer { fixture.finish() }
        for id: Int64 in [1, 2] {
            fixture.service.chatCache.set(id, ChatInfo(
                id: id, title: "Mirror \(id)", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: id
            ))
        }

        let lossy = try await fixture.service.getChatPage(limit: 3)
        XCTAssertEqual(lossy.chats.map(\.id), [1, 2], "chat 3 could not be looked up")
        XCTAssertFalse(lossy.isComplete)

        fixture.service.chatCache.set(3, ChatInfo(
            id: 3, title: "Mirror 3", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 3
        ))
        let whole = try await fixture.service.getChatPage(limit: 3)
        XCTAssertEqual(whole.chats.map(\.id), [1, 2, 3])
        XCTAssertTrue(whole.isComplete)
    }

    func testAnswerWithoutChatIdsIsNotComplete() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(["@type": "chats"]) }
        defer { fixture.finish() }

        let page = try await fixture.service.getChatPage(limit: 10)

        XCTAssertTrue(page.chats.isEmpty)
        XCTAssertFalse(page.isComplete)
    }

    func testLoadChatsIsSkippedWhileItsOwnServerLimitLasts() async throws {
        let fixture = ScriptedServiceFixture(script: Self.emptyPages())
        defer { fixture.finish() }
        await fixture.service.throttle.reportFloodWait(seconds: 600, method: "loadChats")

        let chats = try await fixture.service.getChats(limit: 10)

        XCTAssertTrue(chats.isEmpty)
        XCTAssertEqual(fixture.transport.methods, ["getChats"],
                       "loadChats was sent through a server limit, so it bypasses the throttle")
    }

    func testGetChatsReadsThePageAgainOnlyAfterLoadChatsFinished() async throws {
        let fixture = ScriptedServiceFixture(script: Self.emptyPages(loadChatsDelay: 0.15))
        defer { fixture.finish() }

        _ = try await fixture.service.getChats(limit: 10)

        XCTAssertEqual(fixture.transport.events, [
            "-> getChats", "<- getChats",
            "-> loadChats", "<- loadChats",
            "-> getChats", "<- getChats"
        ], "loadChats has to be awaited, not left running in the background")
    }

    func testConcurrentShortPagesShareOneLoadChats() async throws {
        let fixture = ScriptedServiceFixture(script: Self.emptyPages(loadChatsDelay: 0.2))
        defer { fixture.finish() }

        async let first = fixture.service.getChats(limit: 10)
        async let second = fixture.service.getChats(limit: 10)
        async let third = fixture.service.getChats(limit: 10)
        _ = try await (first, second, third)

        XCTAssertEqual(fixture.transport.requests(ofType: "loadChats").count, 1,
                       "Callers waiting for the same warm-up each sent their own loadChats")
    }

    func testUnknownChatListIsLoadedOnceAndReadAgain() async throws {
        let readCount = ReadCounter()
        let fixture = ScriptedServiceFixture { request in
            switch request["@type"] as? String {
            case "getChats":
                // TDLib does not know a folder list until it was loaded once.
                return readCount.next() <= 3
                    ? .error(code: 400, message: "Chat list not found")
                    : .result(["@type": "chats", "chat_ids": [Int64]()])
            case "loadChats":
                return .delayed(0.2, ["@type": "ok"])
            default:
                return .error(code: 400, message: "Unexpected request")
            }
        }
        defer { fixture.finish() }

        async let first = fixture.service.getChats(limit: 10, folderId: 7)
        async let second = fixture.service.getChats(limit: 10, folderId: 7)
        async let third = fixture.service.getChats(limit: 10, folderId: 7)
        _ = try await (first, second, third)

        XCTAssertEqual(fixture.transport.requests(ofType: "loadChats").count, 1,
                       "Each caller that hit 'Chat list not found' loaded the list on its own")
    }

    func testCacheMissFallbackKeepsAtMostFourChatReadsInFlight() async throws {
        let ids = (1...12).map(Int64.init)
        let fixture = ScriptedServiceFixture { request in
            switch request["@type"] as? String {
            case "getChats":
                return .result(["@type": "chats", "chat_ids": ids])
            case "getChat":
                let id = request["chat_id"] as? Int64 ?? 0
                return .delayed(0.05, ["@type": "chat", "id": id, "title": "Chat \(id)",
                                       "type": ["@type": "chatTypePrivate", "user_id": id]])
            default:
                return .error(code: 400, message: "Unexpected request")
            }
        }
        defer { fixture.finish() }

        let chats = try await fixture.service.getChats(limit: 12)

        XCTAssertEqual(chats.map(\.id), ids, "Every missing chat still has to be fetched")
        let peak = fixture.transport.peakInFlight(ofType: "getChat")
        XCTAssertLessThanOrEqual(peak, 4, "\(peak) local chat reads were in flight at once")
        XCTAssertGreaterThan(peak, 1, "The fallback should still overlap its reads")
    }

    // MARK: - Fixtures

    /// getChats always answers an empty page, which is shorter than the limit
    /// and so makes the service ask TDLib to load more with loadChats.
    private static func emptyPages(loadChatsDelay: TimeInterval = 0) -> ScriptedTDTransport.Script {
        { request in
            switch request["@type"] as? String {
            case "getChats":
                return .result(["@type": "chats", "chat_ids": [Int64]()])
            case "loadChats":
                let ok: [String: Any] = ["@type": "ok"]
                return loadChatsDelay > 0 ? .delayed(loadChatsDelay, ok) : .result(ok)
            default:
                return .error(code: 400, message: "Unexpected request")
            }
        }
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1
    return count
    } }
}
