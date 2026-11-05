import XCTest
@testable import OrbitextWatch

final class TDChatListLoadingTests: XCTestCase {
    func testEmptyInitialPageWarmsOnceAndReturnsLoadedChats() async throws {
        let fixture = Fixture(initialIDs: [], warmedIDs: [42])
        defer { fixture.finish() }

        let chats = try await fixture.service.getChats(limit: 10)

        XCTAssertEqual(chats.map(\.id), [42])
        XCTAssertEqual(fixture.transport.methods, ["getChats", "loadChats", "getChats"])
        XCTAssertEqual(fixture.transport.limits, [10, 10, 10])
    }

    func testStillEmptyAfterWarmupDoesNotLoopOrLoadAllChats() async throws {
        let fixture = Fixture(initialIDs: [], warmedIDs: [])
        defer { fixture.finish() }

        let chats = try await fixture.service.getChats(limit: 10)

        XCTAssertTrue(chats.isEmpty)
        XCTAssertEqual(fixture.transport.methods, ["getChats", "loadChats", "getChats"])
    }

    func testCompleteInitialPageSkipsWarmup() async throws {
        let ids = (1...10).map(Int64.init)
        let fixture = Fixture(initialIDs: ids, warmedIDs: ids)
        defer { fixture.finish() }

        let chats = try await fixture.service.getChats(limit: 10)

        XCTAssertEqual(chats.map(\.id), ids)
        XCTAssertEqual(fixture.transport.methods, ["getChats"])
    }

    private final class Fixture {
        let service: TDLibService
        let transport: Transport
        let client: TDJsonWrapper

        init(initialIDs: [Int64], warmedIDs: [Int64]) {
            service = TDLibService(requestThrottle: TDRequestThrottle(minSpacing: .zero))
            transport = Transport(initialIDs: initialIDs, warmedIDs: warmedIDs)
            client = transport.wrapper()
            service.session.replaceClientForTesting(client)
            for id in Set(initialIDs + warmedIDs) {
                service.chatCache.set(id, ChatInfo(id: id, title: "Offline fixture", lastMessage: nil,
                                                 unreadCount: 0, isGroup: false, isMuted: false, order: id))
            }
            client.startReceiveLoop { _ in }
        }

        func finish() {
            client.stop()
            service.session.replaceClientForTesting(nil)
        }
    }

    /// JSON I/O only: no native client is created and no Telegram requests run.
    private final class Transport: @unchecked Sendable {
        private let condition = NSCondition()
        private let initialIDs: [Int64]
        private let warmedIDs: [Int64]
        private var requests: [[String: Any]] = []
        private var responses: [String] = []
        private var warmed = false
        private var closing = false
        private let clientID: Int32 = 8042
        var methods: [String] { condition.withLock { requests.compactMap { $0["@type"] as? String } } }
        var limits: [Int] { condition.withLock { requests.compactMap { $0["limit"] as? Int } } }

        init(initialIDs: [Int64], warmedIDs: [Int64]) {
            self.initialIDs = initialIDs
            self.warmedIDs = warmedIDs
        }

        func wrapper() -> TDJsonWrapper {
            TDJsonWrapper(clientId: clientID, send: { [self] _, json in send(json) },
                          receive: { [self] in receive(timeout: $0) })
        }

        private func send(_ json: String) {
            let request = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            condition.lock()
            defer { condition.unlock() }
            let type = request["@type"] as? String ?? ""
            var response: [String: Any]
            switch type {
            case "getChats":
                requests.append(request)
                response = ["@type": "chats", "chat_ids": warmed ? warmedIDs : initialIDs]
            case "loadChats":
                requests.append(request)
                warmed = true
                response = ["@type": "ok"]
            case "close":
                closing = true
                response = ["@type": "updateAuthorizationState",
                            "authorization_state": ["@type": "authorizationStateClosed"]]
            default:
                response = ["@type": "error", "code": 400, "message": "Unexpected offline fixture request"]
            }
            response["@extra"] = request["@extra"]
            response["@client_id"] = clientID
            let data = try! JSONSerialization.data(withJSONObject: response)
            responses.append(String(decoding: data, as: UTF8.self))
            condition.broadcast()
        }

        private func receive(timeout: Double) -> String? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while responses.isEmpty {
                if closing || timeout == 0 || !condition.wait(until: deadline) { return nil }
            }
            return responses.removeFirst()
        }
    }
}
