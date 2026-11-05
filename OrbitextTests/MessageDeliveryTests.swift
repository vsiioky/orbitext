import XCTest
@testable import OrbitextWatch

@MainActor
final class MessageDeliveryTests: XCTestCase {
    func testFailedHistoryMessageIsNotDisplayedAsSent() throws {
        let service = TDLibService()
        defer { service.session.finishEventsForTesting() }
        let message = try XCTUnwrap(service.parseMessageInfo(Self.message(id: 101, state: "messageSendingStateFailed")))

        XCTAssertEqual(Self.status(message), "failed")
        XCTAssertFalse(message.isSending)
    }

    func testNativeSendSuccessReplacesTemporaryMessageInOpenChat() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let pending = Self.message(id: -1, state: "messageSendingStatePending")
        let pendingMessage = try XCTUnwrap(fixture.native.parseMessageInfo(pending))
        var cachedChat = fixture.app.chatRepository.chats[0]
        cachedChat.lastMessage = pendingMessage
        fixture.native.chatCache.set(42, cachedChat)
        fixture.native.replyMessageCache.set(MessageKey(chatId: 42, messageId: -1), TDApi.decodeMessage(pending))
        fixture.native.replyMessageCache.set(MessageKey(chatId: 43, messageId: -1), TDApi.decodeMessage(pending))
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        fixture.native.handleUpdate([
            "@type": "updateMessageSendSucceeded", "old_message_id": -1,
            "message": Self.message(id: 101)
        ])

        await fixture.applyEvents()

        let rows = fixture.app.chatMessageStore.messages(for: 42)
        XCTAssertEqual(rows.map(\.id), [101], "The temporary row must be replaced by the server ID without reopening the chat")
        XCTAssertEqual(rows.first.map(Self.status), "sent")
        XCTAssertEqual(fixture.native.chatCache.get(42)?.lastMessage?.id, 101)
        XCTAssertNil(fixture.native.replyMessageCache.get(MessageKey(chatId: 42, messageId: -1)))
        XCTAssertNotNil(fixture.native.replyMessageCache.get(MessageKey(chatId: 42, messageId: 101)))
        XCTAssertNotNil(fixture.native.replyMessageCache.get(MessageKey(chatId: 43, messageId: -1)))
        fixture.app.chatRepository.chatListCache.flush()
        XCTAssertEqual(fixture.app.chatRepository.chatListCache.load()?.first?.lastMessage?.id, 101)
    }

    func testNativeSendFailureUpdatesTemporaryRowWithoutEnqueueingDuplicate() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        fixture.native.handleUpdate([
            "@type": "updateMessageSendFailed", "old_message_id": -1,
            "message": Self.message(id: -2, state: "messageSendingStateFailed"),
            "error": ["@type": "error", "code": 400, "message": "CHAT_WRITE_FORBIDDEN"]
        ])

        await fixture.applyEvents()

        let rows = fixture.app.chatMessageStore.messages(for: 42)
        XCTAssertEqual(rows.map(\.id), [-2])
        XCTAssertEqual(rows.first.map(Self.status), "failed")
        XCTAssertEqual(rows.first?.sendingFailure?.message, "CHAT_WRITE_FORBIDDEN")
        XCTAssertFalse(rows.first?.isEditable ?? true)
        XCTAssertEqual(fixture.app.messageManager.messageQueue.pendingMessages.map(\.id), fixture.priorQueueIDs, "TDLib-owned failed sends must not be automatically submitted again by the app queue")
    }

    func testFailureReasonSurvivesCacheRoundTrip() throws {
        let service = TDLibService()
        defer { service.session.finishEventsForTesting() }
        var raw = Self.message(id: -1)
        raw["sending_state"] = [
            "@type": "messageSendingStateFailed",
            "error": ["@type": "error", "code": 403, "message": "Current refusal"],
            "can_retry": false
        ] as [String: Any]
        var message = try XCTUnwrap(service.parseMessageInfo(raw))
        message.isRead = true // A read watermark must not disguise failure.
        let decoded = try JSONDecoder().decode(MessageInfo.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.sendingFailure, MessageSendFailure(code: 403, message: "Current refusal"))
        XCTAssertEqual(decoded.sendingFailure, message.sendingFailure)
        XCTAssertEqual(decoded.deliveryState, .failed)

        let old = try XCTUnwrap(service.parseMessageInfo(Self.message(id: 101)))
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        oldJSON.removeValue(forKey: "sendingFailure")
        let decodedOld = try JSONDecoder().decode(MessageInfo.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertEqual(decodedOld.deliveryState, .sent)
    }

    func testSuccessBeforeSendResponseDoesNotReinsertPendingRowOrQueueDuplicate() async {
        let transport = Transport(heldMethod: "sendMessage", response: Self.message(id: -1, state: "messageSendingStatePending"))
        let fixture = Fixture(transport: transport)
        defer { fixture.finish() }
        let send = Task { await fixture.app.messageManager.sendMessage(chatId: 42, text: "Offline delivery fixture") }
        await waitForRequest(transport)
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        fixture.native.handleUpdate(["@type": "updateMessageSendSucceeded", "old_message_id": -1, "message": Self.message(id: 101)])
        await fixture.applyEvents()
        XCTAssertEqual(fixture.app.chatMessageStore.messages(for: 42).map(\.id), [101])

        transport.releaseResponse()
        let outcome = await send.value

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(fixture.app.chatMessageStore.messages(for: 42).map(\.id), [101])
        XCTAssertEqual(fixture.app.chatMessageStore.messages(for: 42).first?.deliveryState, .sent)
        XCTAssertEqual(transport.methods, ["sendMessage"])
        XCTAssertEqual(fixture.app.messageManager.messageQueue.pendingMessages.map(\.id), fixture.priorQueueIDs)
    }

    func testStaleInitialHistoryCannotRestoreTemporaryIDAfterSuccess() async throws {
        try await assertHistoryMerge(historyTarget: Self.message(id: -1, state: "messageSendingStatePending"), deleteAfterSuccess: false)
    }

    func testInitialHistoryServerRowAndLivePromotionStayUniqueAndRead() async throws {
        try await assertHistoryMerge(historyTarget: Self.message(id: 101), deleteAfterSuccess: false)
    }

    func testDeleteAfterPromotionDuringHistoryLoadDoesNotResurrectEitherID() async throws {
        try await assertHistoryMerge(historyTarget: Self.message(id: -1, state: "messageSendingStatePending"), deleteAfterSuccess: true)
    }

    func testTerminalAfterChatResetAppearsEvenWhenHistoryOmitsBothIDs() async throws {
        try await assertHistoryMerge(historyTarget: Self.message(id: 999), deleteAfterSuccess: false, resetBeforeLoad: true)
    }

    func testDeleteBeforeTerminalDuringInitialLoadSuppressesBothIDsAndLaterPromotion() async throws {
        try await assertHistoryMerge(historyTarget: Self.message(id: 101), deleteAfterSuccess: false, deleteBeforeSuccess: true)
    }

    private func assertHistoryMerge(historyTarget: [String: Any], deleteAfterSuccess: Bool, resetBeforeLoad: Bool = false, deleteBeforeSuccess: Bool = false) async throws {
        var history = [historyTarget]
        for id in 1..<AppConstants.Message.defaultLoadLimit {
            history.append(Self.message(id: Int64(1_000 + id)))
        }
        let transport = Transport(heldMethod: "getChatHistory", response: ["@type": "messages", "messages": history])
        let fixture = Fixture(transport: transport)
        defer { fixture.finish() }
        if resetBeforeLoad {
            try fixture.app.chatMessageStore.handleIncomingMessage(XCTUnwrap(fixture.native.parseMessageInfo(Self.message(id: -1, state: "messageSendingStatePending"))))
            fixture.app.chatMessageStore.reset(chatId: 42)
        }
        fixture.app.chatRepository.chats[0].lastReadOutboxMessageId = 101
        let load = Task { await fixture.app.chatMessageStore.loadInitialMessages(chatId: 42) }
        await waitForRequest(transport)
        if !resetBeforeLoad {
            fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        }
        if deleteBeforeSuccess {
            fixture.native.handleUpdate(["@type": "updateDeleteMessages", "chat_id": Int64(42), "message_ids": [Int64(-1)], "is_permanent": true])
        }
        fixture.native.handleUpdate(["@type": "updateMessageSendSucceeded", "old_message_id": -1, "message": Self.message(id: 101)])
        if deleteBeforeSuccess {
            fixture.native.handleUpdate(["@type": "updateMessageSendSucceeded", "old_message_id": 101, "message": Self.message(id: 102)])
        }
        if deleteAfterSuccess {
            fixture.native.handleUpdate(["@type": "updateDeleteMessages", "chat_id": Int64(42), "message_ids": [Int64(101)], "is_permanent": true])
        }
        await fixture.applyEvents()
        transport.releaseResponse()

        _ = await load.value

        let rows = fixture.app.chatMessageStore.messages(for: 42)
        XCTAssertFalse(rows.contains { $0.id == -1 })
        let wasDeleted = deleteAfterSuccess || deleteBeforeSuccess
        XCTAssertEqual(rows.filter { $0.id == 101 }.count, wasDeleted ? 0 : 1)
        XCTAssertFalse(rows.contains { $0.id == 102 })
        if !wasDeleted { XCTAssertEqual(rows.first(where: { $0.id == 101 })?.deliveryState, .read) }
        XCTAssertEqual(transport.methods, ["getChatHistory"])
    }

    func testCompletionIsScopedToChatAndDoesNotOverwriteNewerLastMessage() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let store = fixture.app.chatMessageStore
        let mock = try XCTUnwrap(fixture.app.service as? MockTelegramService)
        mock.defaultMessageProperties = MessageProperties(isResolved: true)
        var foreign = Self.message(id: -1, state: "messageSendingStatePending")
        foreign["chat_id"] = Int64(43)
        store.reset(chatId: 43)
        try store.handleIncomingMessage(XCTUnwrap(fixture.native.parseMessageInfo(foreign)))
        _ = await store.fetchMessageProperties(chatId: 43, messageId: -1)
        _ = await store.fetchMessageProperties(chatId: 42, messageId: -1)
        _ = await store.fetchMessageProperties(chatId: 42, messageId: 101)
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: 102)])
        fixture.native.handleUpdate(["@type": "updateMessageSendSucceeded", "old_message_id": -1, "message": Self.message(id: 101)])
        await fixture.applyEvents()

        XCTAssertEqual(store.messages(for: 43).map(\.id), [-1])
        XCTAssertEqual(store.messages(for: 43).first?.deliveryState, .sending)
        XCTAssertNotNil(store.cachedProperties(chatId: 43, messageId: -1))
        XCTAssertNil(store.cachedProperties(chatId: 42, messageId: -1))
        XCTAssertNil(store.cachedProperties(chatId: 42, messageId: 101))
        XCTAssertEqual(fixture.app.chatRepository.chats[0].lastMessage?.id, 102)
    }

    func testFailureWithUnchangedIDUpdatesSingleRowAndTerminalErrorFallback() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        fixture.native.handleUpdate(["@type": "updateNewMessage", "message": Self.message(id: -1, state: "messageSendingStatePending")])
        fixture.native.handleUpdate(["@type": "updateMessageSendFailed", "old_message_id": -1,
                                     "message": Self.message(id: -1),
                                     "error": ["@type": "error", "code": 429, "message": "Fixture refusal"]])
        await fixture.applyEvents()
        let rows = fixture.app.chatMessageStore.messages(for: 42)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sendingFailure, MessageSendFailure(code: 429, message: "Fixture refusal"))
        XCTAssertEqual(rows.first?.deliveryState.accessibilityLabel, L10n.string("Failed"))
    }

    func testLRURemovalPreservesRecencyLinksForPromotionInvalidation() {
        let cache = LRUThreadSafeCache<Int, Int>(maxSize: 3)
        for id in 1...3 { cache.set(id, id) }
        cache.remove(2)
        cache.remove(1)
        cache.remove(3)
        XCTAssertEqual(cache.count, 0)
        for id in 4...7 { cache.set(id, id) }
        XCTAssertNil(cache.get(4))
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.get(7), 7)
    }

    private func waitForRequest(_ transport: Transport) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.methods.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(transport.methods.isEmpty, "Offline transport must observe the request before emitting terminal updates")
    }

    private static func status(_ message: MessageInfo) -> String {
        switch StateIconView(message: message).state {
        case .sending: return "sending"
        case .sent: return "sent"
        case .read: return "read"
        case .failed: return "failed"
        }
    }

    private static func message(id: Int64, state: String? = nil) -> [String: Any] {
        var message: [String: Any] = [
            "@type": "message", "id": id, "chat_id": Int64(42),
            "date": 1_700_000_000, "is_outgoing": true,
            "sender_id": ["@type": "messageSenderUser", "user_id": Int64(42)],
            "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": "Offline delivery fixture", "entities": []]]
        ]
        if let state {
            message["sending_state"] = [
                "@type": state,
                "error": ["@type": "error", "code": 400, "message": "CHAT_WRITE_FORBIDDEN"]
            ] as [String: Any]
        }
        return message
    }

    @MainActor
    private final class Fixture {
        let native: TDLibService
        let app: AppState
        let priorCache: [ChatInfo]?
        let priorQueueIDs: [UUID]
        let client: TDJsonWrapper?

        init(transport: Transport? = nil) {
            let native = TDLibService(requestThrottle: TDRequestThrottle(minSpacing: .zero))
            self.native = native
            let client = transport?.wrapper()
            self.client = client
            if let client {
                native.session.replaceClientForTesting(client)
                native.userCache.set(42, .sample(id: 42, firstName: "Offline", lastName: "fixture"))
                client.startReceiveLoop { _ in }
            }
            priorCache = ListCache<ChatInfo>(filename: "cached_chats.json").load()
            let service: any TelegramServiceProtocol = transport == nil ? MockTelegramService() : native
            app = AppState(service: service, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
            priorQueueIDs = app.messageManager.messageQueue.pendingMessages.map(\.id)
            app.chatRepository.chats = [ChatInfo(id: 42, title: "Offline fixture", lastMessage: nil,
                                                unreadCount: 0, isGroup: false, isMuted: false, order: 100)]
            // The chat these tests are about is the one on screen.
            app.chatMessageStore.reset(chatId: 42)
        }

        func applyEvents() async {
            native.session.finishEventsForTesting()
            for await event in native.events { app.handleEvent(event) }
        }

        func finish() {
            client?.stop()
            native.session.replaceClientForTesting(nil)
            native.session.finishEventsForTesting()
            app.chatRepository.invalidateChatListPrefetch()
            app.chatRepository.missingChatFetchTask?.cancel()
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            if let priorCache {
                app.chatRepository.chatListCache.save(priorCache)
                app.chatRepository.chatListCache.flush()
            } else {
                app.chatRepository.chatListCache.clear()
            }
        }
    }

    /// Holds one injected JSON response until the test has applied native updates.
    /// No native client, database, account, or network is used.
    private final class Transport: @unchecked Sendable {
        private let condition = NSCondition()
        private let heldMethod: String
        private let response: [String: Any]
        private var requests: [String] = []
        private var heldResponse: [String: Any]?
        private var responses: [String] = []
        private var isReleased = false
        private var closing = false
        private let clientID: Int32 = 8142
        var methods: [String] { condition.withLock { requests } }

        init(heldMethod: String, response: [String: Any]) {
            self.heldMethod = heldMethod
            self.response = response
        }

        func wrapper() -> TDJsonWrapper {
            TDJsonWrapper(clientId: clientID, send: { [self] _, json in send(json) },
                          receive: { [self] in receive(timeout: $0) })
        }

        func releaseResponse() {
            condition.lock()
            defer { condition.unlock() }
            isReleased = true
            if let heldResponse { enqueue(heldResponse) }
            heldResponse = nil
        }

        private func send(_ json: String) {
            let request = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            condition.lock()
            defer { condition.unlock() }
            let method = request["@type"] as? String ?? ""
            var response: [String: Any]
            if method == "close" {
                closing = true
                response = ["@type": "updateAuthorizationState", "authorization_state": ["@type": "authorizationStateClosed"]]
            } else {
                requests.append(method)
                response = method == heldMethod ? self.response : ["@type": "error", "code": 400, "message": "Unexpected offline fixture request"]
            }
            response["@extra"] = request["@extra"]
            response["@client_id"] = clientID
            if method == heldMethod, !isReleased { heldResponse = response } else { enqueue(response) }
        }

        private func enqueue(_ response: [String: Any]) {
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
