import XCTest
@testable import OrbitextWatch

/// Regression tests, plus ownership/cancellation boundaries.
@MainActor
final class LifecycleAuditTests: XCTestCase {
    func testSyncDrainTimeoutReturnsWhileRunningRequestIsStillBlocked() async throws {
        let app = makeApp(service: MockTelegramService())
        let gate = LifecycleAuditGate()
        let blockedSync = Task { await gate.wait() }
        app.syncTask = blockedSync
        while !gate.isWaiting { await Task.yield() }

        var drainReturned = false
        let drain = Task {
            await app.waitForSyncPipelineToDrain(timeout: 0.02)
            drainReturned = true
        }
        try await Task.sleep(for: .milliseconds(150))
        let returnedBeforeGateReleased = drainReturned

        // Always release suspended work, including when the expectation fails.
        app.syncTask = nil
        gate.release()
        await blockedSync.value
        await drain.value

        XCTAssertTrue(returnedBeforeGateReleased,
                      "The 20ms sync deadline was ignored while awaiting the running task; it remained blocked after 150ms")
    }

    func testPushCompletionDoesNotSuspendTransportAfterAppBecomesActive() async throws {
        let service = MockTelegramService()
        service.authState = .ready
        service.remotePushResult = true
        service.emitReadyConnectionOnResume = false
        let app = makeApp(service: service)
        app.isInitialized = true
        app.authManager.authState = .ready
        app.chatRepository.isInBackgroundState = true

        let push = Task { await app.handleRemotePush(userInfo: ["aps": ["content-available": 1]]) }
        let deadline = ContinuousClock.now + .seconds(2)
        while service.handledRemotePushPayloads.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(service.handledRemotePushPayloads.count, 1)

        // The push is in its 750ms processing debounce. Activation resumes TDLib.
        // Use the existing activation debounce to keep this test focused on
        // transport ownership, without introducing foreground queue work.
        app.lastBecameActiveTime = .now
        app.handleBecameActive()
        let suspendsAfterActivation = service.suspendCallCount
        XCTAssertFalse(app.chatRepository.isInBackgroundState)

        _ = await push.value
        app.networkMonitor.pause()
        app.resetSyncPipeline()

        XCTAssertEqual(service.suspendCallCount, suspendsAfterActivation,
                       "An older push handler suspended TDLib after the foreground transition resumed it")
        XCTAssertFalse(app.chatRepository.isInBackgroundState)
    }

    func testAuthMethodResetStillConsumesLaterAuthEvents() async throws {
        let service = MockTelegramService()
        service.authState = .waitPhoneNumber
        let app = makeApp(service: service)
        await app.initialize()
        let initialDeadline = ContinuousClock.now + .seconds(1)
        while app.authManager.authState != .waitPhoneNumber && ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
        // Ensure the first event consumer has returned to its suspended next().
        try await Task.sleep(for: .milliseconds(20))

        await app.resetAuthMethodSelection()
        try await Task.sleep(for: .milliseconds(20))
        service.emit(.authStateChanged(.waitCode))
        let deadline = ContinuousClock.now + .milliseconds(150)
        while app.authManager.authState != .waitCode && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }

        let finalState = app.authManager.authState
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
        XCTAssertEqual(finalState, .waitCode,
                       "Resetting the auth method cancelled the original AsyncStream consumer; the replacement consumer no longer receives auth events")
    }

    func testZeroDeadlineLeavesPendingSyncIntact() async {
        let app = makeApp(service: MockTelegramService())
        app.pendingSyncRequest = .init(loadChats: true, reasons: ["waiting_for_auth"])

        let result = await app.waitForSyncPipelineToDrain(timeout: 0)

        XCTAssertEqual(result, .timedOut)
        XCTAssertTrue(app.pendingSyncRequest.loadChats)
        app.resetSyncPipeline()
    }

    func testSyncDrainCancellationReturnsWithoutCancellingSharedWork() async throws {
        let app = makeApp(service: MockTelegramService())
        let gate = LifecycleAuditGate()
        let blockedSync = Task { await gate.wait() }
        app.syncTask = blockedSync
        while !gate.isWaiting { await Task.yield() }
        var result: AppState.SyncDrainResult?
        let drain = Task { result = await app.waitForSyncPipelineToDrain() }
        await Task.yield()
        drain.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let resultBeforeRelease = result
        let sharedWorkCancelled = blockedSync.isCancelled

        app.syncTask = nil
        gate.release()
        await blockedSync.value
        await drain.value

        XCTAssertEqual(resultBeforeRelease, .cancelled)
        XCTAssertFalse(sharedWorkCancelled)
    }

    func testOneTimedOutWaiterDoesNotEndAnotherWaitersSync() async {
        let app = makeApp(service: MockTelegramService())
        let gate = LifecycleAuditGate()
        let blockedSync = Task { await gate.wait() }
        app.syncTask = blockedSync
        while !gate.isWaiting { await Task.yield() }
        var longerResult: AppState.SyncDrainResult?
        let longerWaiter = Task { longerResult = await app.waitForSyncPipelineToDrain(timeout: 1) }

        let shortResult = await app.waitForSyncPipelineToDrain(timeout: 0.02)
        XCTAssertEqual(shortResult, .timedOut)
        XCTAssertNil(longerResult)
        XCTAssertFalse(blockedSync.isCancelled)
        app.syncTask = nil
        gate.release()
        await blockedSync.value
        await longerWaiter.value
        XCTAssertEqual(longerResult, .drained)
    }

    func testCancelledPendingDrainDoesNotSpinOrDiscardQueuedRequest() async {
        let app = makeApp(service: MockTelegramService())
        app.pendingSyncRequest = .init(loadChats: true, reasons: ["waiting_for_auth"])
        let waiter = Task { await app.waitForSyncPipelineToDrain() }
        waiter.cancel()

        let result = await waiter.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(app.pendingSyncRequest.loadChats)
        app.resetSyncPipeline()
    }

    func testPushArrivingWhileForegroundPreservesForegroundState() async {
        let service = MockTelegramService()
        service.remotePushResult = false
        let app = makeApp(service: service)
        app.isInitialized = true
        app.handleBecameActive()

        _ = await app.handleRemotePush(userInfo: [:])

        XCTAssertFalse(app.chatRepository.isInBackgroundState)
        XCTAssertEqual(service.suspendCallCount, 0)
        app.networkMonitor.pause()
    }

    func testRefreshCompletionDoesNotSuspendNewForegroundSession() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        app.isInitialized = true
        app.authManager.authState = .ready
        let gate = LifecycleAuditGate()
        let blockedSync = Task { await gate.wait() }
        app.syncTask = blockedSync
        while !gate.isWaiting { await Task.yield() }
        let refresh = Task { await app.performBackgroundRefresh() }
        await waitUntil { app.pendingSyncRequest.reasons.contains("background_refresh") }
        XCTAssertTrue(app.pendingSyncRequest.loadChats)
        app.lastBecameActiveTime = .now
        app.handleBecameActive()
        let suspendsAfterActivation = service.suspendCallCount

        app.pendingSyncRequest = .init()
        app.syncTask = nil
        gate.release()
        await blockedSync.value
        await refresh.value

        XCTAssertEqual(service.suspendCallCount, suspendsAfterActivation)
        XCTAssertFalse(app.chatRepository.isInBackgroundState)
        XCTAssertEqual((app.widgetSync as? MockWidgetSync)?.updates.last?.isInBackground, false)
        app.networkMonitor.pause()
    }

    func testCancelledPushDoesNotSuspendOverlappingRefresh() async {
        let service = MockTelegramService()
        service.remotePushResult = true
        let app = makeApp(service: service)
        app.isInitialized = true
        app.authManager.authState = .ready
        let gate = LifecycleAuditGate()
        let blockedSync = Task { await gate.wait() }
        app.syncTask = blockedSync
        while !gate.isWaiting { await Task.yield() }
        let refresh = Task { await app.performBackgroundRefresh() }
        await waitUntil { app.pendingSyncRequest.reasons.contains("background_refresh") }
        let push = Task { await app.handleRemotePush(userInfo: [:]) }
        await waitUntil { !service.handledRemotePushPayloads.isEmpty }
        XCTAssertEqual(service.handledRemotePushPayloads.count, 1)
        push.cancel()
        _ = await push.value
        XCTAssertEqual(service.suspendCallCount, 0, "Refresh still owns transport after cancelled push ends")

        app.handleEnteredBackground()
        XCTAssertEqual(service.suspendCallCount, 0, "Scene background must preserve an active refresh")
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(service.suspendCallCount, 1, "Final background owner releases transport")
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        app.pendingSyncRequest = .init()
        app.syncTask = nil
        gate.release()
        await blockedSync.value
    }

    func testRepeatedAuthResetAndRetryKeepReceivingEvents() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        await app.initialize()
        await waitUntil { app.authManager.authState == .waitPhoneNumber }
        for nextState in [AuthState.waitCode, .waitPassword(hint: "Test hint"), .waitCode] {
            await app.resetAuthMethodSelection()
            service.emit(.authStateChanged(nextState))
            await waitUntil { app.authManager.authState == nextState }
            XCTAssertEqual(app.authManager.authState, nextState)
        }
        await app.retry()
        service.emit(.authStateChanged(.waitPassword(hint: "Test hint")))
        await waitUntil { app.authManager.authState == .waitPassword(hint: "Test hint") }
        XCTAssertEqual(app.authManager.authState, .waitPassword(hint: "Test hint"))
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testCancelledOldSyncCannotClearItsReplacement() async throws {
        let service = MockTelegramService()
        service.getChatFoldersDelay = .seconds(1)
        service.getChatsDelay = .milliseconds(300)
        let app = makeApp(service: service)
        app.authManager.authState = .ready
        app.enqueueSync(.init(loadFolders: true, reasons: ["old"]))
        await waitUntil { app.chatRepository.isLoadingFolders }
        XCTAssertTrue(app.chatRepository.isLoadingFolders)
        app.resetSyncPipeline()
        app.enqueueSync(.init(loadChats: true, reasons: ["replacement"]))
        await waitUntil { !service.getChatsRequests.isEmpty }
        // The mock's cancelled folder sleep returns before replacement load.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(app.syncTask, "An older completion must not clear the current sync owner")
        let result = await app.waitForSyncPipelineToDrain(timeout: 1)
        XCTAssertEqual(result, .drained)
        app.resetSyncPipeline()
    }

    func testAuthResetClearsPreservedSessionAfterFailedLogout() async {
        let service = MockTelegramService()
        service.logoutError = TestError.failed("close failed")
        let app = makeApp(service: service)
        app.chatRepository.chats = [ChatInfo(id: 77, title: "Old session", lastMessage: nil,
                                            unreadCount: 0, isGroup: false, isMuted: false, order: 1)]
        app.chatRepository.folderFilterEnabled = true
        app.chatRepository.selectedFolderId = 7
        app.chatRepository.draftStore.setDraft(chatId: 77, text: "Old draft")
        app.messageManager.messageQueue.enqueue(chatId: 77, text: "Old queued message")

        await app.logout()
        XCTAssertEqual(app.chatRepository.chats.map(\.id), [77])
        XCTAssertTrue(app.messageManager.messageQueue.hasPending)
        XCTAssertEqual(app.authManager.authState, .error("close failed"))

        await app.resetAuthMethodSelection()

        XCTAssertTrue(app.chatRepository.chats.isEmpty)
        XCTAssertTrue(app.chatRepository.draftStore.allDrafts().isEmpty)
        XCTAssertFalse(app.messageManager.messageQueue.hasPending)
        XCTAssertFalse(app.chatRepository.folderFilterEnabled)
        XCTAssertEqual(app.chatRepository.selectedFolderId, 0)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationReplyOnColdStartStartsClientAndSendsText() async {
        let service = MockTelegramService()
        service.authState = .ready
        let app = makeApp(service: service)

        // watchOS can deliver the action before any view has run initialize().
        let reply = Task { await app.notificationManager.onReply?(7, "On my way") }
        await waitUntil { !service.sentMessages.isEmpty }
        completeSends(service, chatId: 7)
        await reply.value

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.sentMessages.map(\.chatId), [7])
        XCTAssertEqual(service.sentMessages.map(\.text), ["On my way"],
                       "The dictated reply was dropped before the client was ready")
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationReplyHoldsTransportUntilServerAnswers() async {
        let service = MockTelegramService()
        service.authState = .ready
        let app = makeApp(service: service)
        await app.initialize()
        await waitUntil { app.authManager.authState == .ready }
        let resumesBefore = service.resumeCallCount
        let suspendsBefore = service.suspendCallCount

        var finished = false
        let reply = Task {
            await app.notificationManager.onReply?(7, "Later")
            finished = true
        }
        await waitUntil { !service.sentMessages.isEmpty }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertGreaterThan(service.resumeCallCount, resumesBefore,
                             "The reply was sent while the receive loop could stay paused")
        XCTAssertFalse(finished, "The action finished while the reply was only pending in TDLib")
        XCTAssertEqual(service.suspendCallCount, suspendsBefore,
                       "The transport was suspended before the server answered")
        XCTAssertEqual(app.backgroundOperations.count, 1)

        completeSends(service, chatId: 7)
        await reply.value

        XCTAssertEqual(service.sentMessages.map(\.text), ["Later"])
        XCTAssertEqual(service.suspendCallCount, suspendsBefore + 1,
                       "The background transport lease was not released after the reply")
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        XCTAssertTrue(app.awaitedSendResults.isEmpty)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testPendingReplyIsNotQueuedAgainWhenServerAnswerIsLate() async {
        let service = MockTelegramService()
        service.authState = .ready
        let app = makeApp(service: service)
        app.messageManager.messageQueue.clear()
        defer { app.messageManager.messageQueue.clear() }

        await app.handleNotificationReply(chatId: 7, text: "Pending", deliveryTimeout: 0.05)

        XCTAssertEqual(service.sentMessages.map(\.text), ["Pending"])
        XCTAssertFalse(app.messageManager.messageQueue.hasPending,
                       "TDLib already owns the pending reply; queueing it again would send it twice")
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        XCTAssertTrue(app.awaitedSendResults.isEmpty)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationMarkReadOnColdStartUsesFetchedChat() async {
        let service = MockTelegramService()
        service.authState = .ready
        let lastMessage = MessageInfo(
            id: 99, chatId: 7, senderName: "Alice", senderId: 2,
            content: .text(FormattedString(text: "Hi")), date: Date(),
            isOutgoing: false, isRead: false
        )
        service.chatsById[7] = ChatInfo(id: 7, title: "Alice", lastMessage: lastMessage, unreadCount: 3,
                                        isGroup: false, isMuted: false, order: 1)
        let app = makeApp(service: service)

        // The chat list is still empty on a cold start.
        await app.notificationManager.onMarkRead?(7)

        XCTAssertEqual(service.readReceipts.map(\.chatId), [7])
        XCTAssertEqual(service.readReceipts.map(\.messageId), [99],
                       "Mark as Read did nothing because the chat was not loaded yet")
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationMarkReadFallsBackToTheDirectoryWhenGetChatFails() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.getChatError = TDError.timeout
        let lastMessage = MessageInfo(
            id: 99, chatId: 7, senderName: "Alice", senderId: 2,
            content: .text(FormattedString(text: "Hi")), date: Date(),
            isOutgoing: false, isRead: false
        )
        let app = makeApp(service: service)
        // TDLib announced the chat in this session; it is not in the list on screen.
        app.chatRepository.handleChatPositionUpdate(.init(
            chat: ChatInfo(id: 7, title: "Alice", lastMessage: lastMessage, unreadCount: 3,
                           isGroup: false, isMuted: false, order: 0),
            positions: [],
            source: .newChat
        ))

        await app.notificationManager.onMarkRead?(7)

        XCTAssertEqual(service.readReceipts.map(\.messageId), [99],
                       "Mark as Read gave up although the directory knew the last message")
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationReplyIsQueuedWhenClientIsNotReadyInTime() async {
        let service = MockTelegramService()
        service.authState = .idle
        let app = makeApp(service: service)
        app.messageManager.messageQueue.clear()
        defer { app.messageManager.messageQueue.clear() }

        await app.handleNotificationReply(chatId: 7, text: "Queued", readyTimeout: 0.05)

        XCTAssertTrue(service.sentMessages.isEmpty)
        XCTAssertEqual(app.messageManager.messageQueue.pendingFor(chatId: 7).map(\.text), ["Queued"],
                       "A slow TDLib start must not lose the dictated reply")
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testRefusedNotificationReplyIsKeptAsFailed() async {
        let service = MockTelegramService()
        service.authState = .ready
        service.sendMessageError = TDError.api(code: 400, message: "Chat not found")
        let app = makeApp(service: service)
        app.messageManager.messageQueue.clear()
        defer { app.messageManager.messageQueue.clear() }

        await app.handleNotificationReply(chatId: 7, text: "Refused", readyTimeout: 1)

        XCTAssertEqual(app.messageManager.messageQueue.failedMessages.map(\.text), ["Refused"],
                       "A dictated reply vanished without a trace")
        XCTAssertTrue(app.messageManager.messageQueue.sendableMessages.isEmpty, "It must not be retried on its own")
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testNotificationReplyIsNotQueuedForSignedOutAccount() async {
        let service = MockTelegramService()
        service.authState = .waitPhoneNumber
        let app = makeApp(service: service)
        app.messageManager.messageQueue.clear()
        defer { app.messageManager.messageQueue.clear() }

        await app.notificationManager.onReply?(7, "Stale")

        XCTAssertTrue(service.sentMessages.isEmpty)
        XCTAssertFalse(app.messageManager.messageQueue.hasPending,
                       "A reply for a signed-out account must not reach the next session")
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    // MARK: - Scene and lease ownership of the transport

    func testEnteringBackgroundWithoutLeasesSuspendsTransportOnce() {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        app.handleEnteredBackground()

        XCTAssertEqual(service.suspendCallCount, 1)
        XCTAssertTrue(app.chatRepository.isInBackgroundState)
    }

    func testBecomingActiveResumesTransportEvenBeforeAuthorization() {
        let service = MockTelegramService()
        let app = makeApp(service: service)
        // A started client, so the scene change has nothing to start.
        app.isInitialized = true
        app.chatRepository.isInBackgroundState = true

        app.handleBecameActive()

        XCTAssertEqual(service.resumeCallCount, 1)
        XCTAssertFalse(app.chatRepository.isInBackgroundState)
        XCTAssertTrue(app.pendingSyncRequest.isEmpty, "Nothing can sync before the account is ready")
        app.networkMonitor.pause()
    }

    func testSkippedRefreshStillMarksTheRepositoryAsBackground() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        await app.performBackgroundRefresh()

        XCTAssertEqual(service.resumeCallCount, 0, "A refresh of a client nobody started must not wake the transport")
        XCTAssertTrue(app.chatRepository.isInBackgroundState)
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        XCTAssertEqual(service.suspendCallCount, 1)
    }

    func testConcurrentInitializeStartsTheClientOnce() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        async let first: Void = app.initialize()
        async let second: Void = app.initialize()
        _ = await (first, second)

        XCTAssertEqual(service.startCallCount, 1)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testCancelledNotificationReplyStillSendsWhenAlreadyReady() async {
        let service = MockTelegramService()
        service.authState = .ready
        let app = makeApp(service: service)
        app.isInitialized = true
        app.authManager.authState = .ready
        app.messageManager.messageQueue.clear()
        defer { app.messageManager.messageQueue.clear() }

        // watchOS cancels an action that runs long; the dictated text must
        // still go out when the account is ready, as it does today.
        let reply = Task { await app.handleNotificationReply(chatId: 7, text: "Still sent", deliveryTimeout: 0.05) }
        reply.cancel()
        await reply.value

        XCTAssertEqual(service.sentMessages.map(\.text), ["Still sent"])
        XCTAssertTrue(app.backgroundOperations.isEmpty)
        app.networkMonitor.pause()
    }

    // MARK: - The scene starts the client

    func testSceneActivationStartsTheClient() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        app.handleBecameActive()
        await waitUntil { service.startCallCount == 1 }

        XCTAssertEqual(service.startCallCount, 1, "Nothing but a view task started the client before")
        XCTAssertTrue(app.isInitialized)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    func testRepeatedSceneActivationStartsTheClientOnce() async {
        let service = MockTelegramService()
        let app = makeApp(service: service)

        app.handleBecameActive()
        app.handleBecameActive()
        await waitUntil { service.startCallCount >= 1 }
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(service.startCallCount, 1)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    // MARK: - The chat open on screen does not outlive the session

    func testLogoutForgetsTheChatOpenForNotifications() async {
        let app = makeApp(service: MockTelegramService())
        app.notificationManager.activeChatId = 42
        app.chatMessageStore.setActiveChat(42)

        await app.logout()

        XCTAssertNil(app.chatMessageStore.activeChatId)
        XCTAssertNil(app.notificationManager.activeChatId,
                     "The next account would not be notified about chat 42 until its screen was left")
    }

    func testAuthResetForgetsTheChatOpenForNotifications() async {
        let app = makeApp(service: MockTelegramService())
        app.notificationManager.activeChatId = 42
        app.chatMessageStore.setActiveChat(42)

        await app.resetAuthMethodSelection()

        XCTAssertNil(app.chatMessageStore.activeChatId)
        XCTAssertNil(app.notificationManager.activeChatId)
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    // MARK: - Events of an ended client

    func testLogoutDropsQueuedEventsOfTheEndedClientAndKeepsTheNextOnes() async {
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
        defer { ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats") }
        let service = MockTelegramService()
        let app = makeApp(service: service)
        // Nothing runs the event loop: the consumer is a step behind.
        service.emit(mainListUpdate(chatId: 77, title: "Old account"))
        await app.logout()
        service.emit(mainListUpdate(chatId: 88, title: "New account"))

        // The mock queued: old update, retirement marker, signed out, new update.
        var events = service.events.makeAsyncIterator()
        for _ in 0..<4 {
            if let event = await events.next() { app.handleEvent(event) }
        }

        XCTAssertEqual(app.chatRepository.chats.map(\.id), [88],
                       "An update of the account that signed out reached the next one")
        XCTAssertEqual(app.authManager.authState, .waitPhoneNumber)
    }

    func testAuthResetDropsQueuedEventsOfTheEndedClient() async {
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
        defer { ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats") }
        let service = MockTelegramService()
        let app = makeApp(service: service)
        service.emit(mainListUpdate(chatId: 77, title: "Old account"))

        // The reset starts the event loop, which finds the old update queued.
        await app.resetAuthMethodSelection()
        service.emit(mainListUpdate(chatId: 88, title: "New account"))
        await waitUntil { !app.chatRepository.chats.isEmpty }

        XCTAssertEqual(app.chatRepository.chats.map(\.id), [88])
        app.eventTask?.cancel()
        app.networkMonitor.pause()
        app.resetSyncPipeline()
    }

    private func mainListUpdate(chatId: Int64, title: String) -> TDLibEvent {
        .chatPositionChanged(.init(
            chat: ChatInfo(id: chatId, title: title, lastMessage: nil, unreadCount: 0,
                           isGroup: false, isMuted: false, order: 9),
            positions: [ChatListPosition(list: .main, order: 9, isPinned: false)],
            source: .explicitPosition
        ))
    }

    /// Plays TDLib's updateMessageSendSucceeded for every message the mock accepted.
    private func completeSends(_ service: MockTelegramService, chatId: Int64) {
        for pending in service.messagesByChatId[chatId] ?? [] {
            service.emit(.messageSendCompleted(oldMessageId: pending.id, message: pending))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeApp(service: MockTelegramService) -> AppState {
        let app = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        return app
    }
}

@MainActor
private final class LifecycleAuditGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
