import XCTest
@testable import OrbitextWatch

/// What a `TDLibService` call puts on the wire and what it does around it,
/// observed through a scripted TDLib client.
final class TDLibRequestTests: XCTestCase {
    // MARK: - Reactions

    func testSetReactionAddsTheEmojiAndFeedsRecentReactions() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        try await fixture.service.setReaction(chatId: 42, messageId: 7, emoji: "👍")

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "addMessageReaction").first)
        XCTAssertEqual(request["chat_id"] as? Int64, 42)
        XCTAssertEqual(request["message_id"] as? Int64, 7)
        let reaction = try XCTUnwrap(request["reaction_type"] as? [String: Any])
        XCTAssertEqual(reaction["@type"] as? String, "reactionTypeEmoji")
        XCTAssertEqual(reaction["emoji"] as? String, "👍")
        XCTAssertEqual(request["is_big"] as? Bool, false, "A tap on a reaction plays the small animation")
        XCTAssertEqual(request["update_recent_reactions"] as? Bool, true,
                       "A reaction the user picked belongs in their recent reactions")
    }

    // MARK: - Forwarding

    func testForwardMessageSendsExplicitCopyFlags() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        try await fixture.service.forwardMessage(fromChatId: 10, messageId: 7, toChatId: 20)

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "forwardMessages").first)
        XCTAssertEqual(request["chat_id"] as? Int64, 20)
        XCTAssertEqual(request["from_chat_id"] as? Int64, 10)
        XCTAssertEqual(request["message_ids"] as? [Int64], [7])
        // The installed td_api takes both flags; a forward keeps its origin and caption.
        XCTAssertEqual(request["send_copy"] as? Bool, false)
        XCTAssertEqual(request["remove_caption"] as? Bool, false)
    }

    // MARK: - Remote push

    func testRemotePushReachesTDLibAsJSONTextWithSortedStringKeys() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }
        let payload = try RemotePushPayload(userInfo: ["p": "payload", AnyHashable(1): ["b": 2, "a": 1]])

        let handled = try await fixture.service.handleRemotePush(payload: payload)

        XCTAssertTrue(handled)
        let request = try XCTUnwrap(fixture.transport.requests(ofType: "processPushNotification").first)
        XCTAssertEqual(request["payload"] as? String, #"{"1":{"a":1,"b":2},"p":"payload"}"#)
    }

    func testRemotePushForAnotherReceiverIsDroppedWithoutAskingTDLib() async throws {
        let fixture = ScriptedServiceFixture(execute: Self.pushReceiver(7))
        defer { fixture.finish() }
        fixture.service.push.state.withLock { $0.receiverId = 5 }

        let handled = try await fixture.service.handleRemotePush(payload: RemotePushPayload(json: #"{"p":"x"}"#))

        XCTAssertFalse(handled)
        XCTAssertTrue(fixture.transport.requests(ofType: "processPushNotification").isEmpty)
    }

    func testRemotePushForThisReceiverReachesTDLib() async throws {
        let fixture = ScriptedServiceFixture(execute: Self.pushReceiver(5))
        defer { fixture.finish() }
        fixture.service.push.state.withLock { $0.receiverId = 5 }

        let handled = try await fixture.service.handleRemotePush(payload: RemotePushPayload(json: #"{"p":"x"}"#))

        XCTAssertTrue(handled)
        XCTAssertEqual(fixture.transport.requests(ofType: "processPushNotification").count, 1)
    }

    /// 406 means TDLib needs a sync first; the push is still the app's to
    /// handle, not an error.
    func testRemotePushTDLibAsksToSyncFirstCountsAsHandled() async throws {
        let fixture = ScriptedServiceFixture { request in
            request["@type"] as? String == "processPushNotification"
                ? .error(code: 406, message: "Please sync")
                : .result(["@type": "ok"])
        }
        defer { fixture.finish() }

        let handled = try await fixture.service.handleRemotePush(payload: RemotePushPayload(json: #"{"p":"x"}"#))

        XCTAssertTrue(handled)
    }

    func testRemotePushOtherTDLibErrorsAreThrown() async throws {
        let fixture = ScriptedServiceFixture { request in
            request["@type"] as? String == "processPushNotification"
                ? .error(code: 400, message: "Bad payload")
                : .result(["@type": "ok"])
        }
        defer { fixture.finish() }

        do {
            _ = try await fixture.service.handleRemotePush(payload: RemotePushPayload(json: #"{"p":"x"}"#))
            XCTFail("A rejected payload must not count as handled")
        } catch TDError.api(let code, _) {
            XCTAssertEqual(code, 400)
        }
    }

    func testUnregisterSendsTheEmptyTokenSentinel() throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        let request = fixture.service.push.unregisterRequest

        XCTAssertEqual(request["@type"] as? String, "registerDevice")
        let token = try XCTUnwrap(request["device_token"] as? [String: Any])
        XCTAssertEqual(token["@type"] as? String, "deviceTokenApplePush")
        XCTAssertEqual(token["device_token"] as? String, "")
        XCTAssertEqual(request["other_user_ids"] as? [Int64], [])
    }

    /// The synchronous getPushReceiverId, answered with a fixed receiver.
    private static func pushReceiver(_ id: Int64) -> @Sendable (String) -> String? {
        { _ in #"{"@type":"pushReceiverId","id":"\#(id)"}"# }
    }

    // MARK: - File download

    func testLocalFileURLAsksForTheWholeFileAndWaitsForIt() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { request in
            .result(Self.downloadedFile(path: file.path, completed: request["@type"] as? String == "downloadFile"))
        }
        defer { fixture.finish() }

        let url = try await fixture.service.localFileURL(fileId: "314", priority: .requested)

        XCTAssertEqual(url.path, file.path)
        let request = try XCTUnwrap(fixture.transport.requests(ofType: "downloadFile").first)
        XCTAssertEqual(request["file_id"] as? Int, 314)
        XCTAssertEqual(request["priority"] as? Int, 32)
        XCTAssertEqual(request["offset"] as? Int, 0)
        XCTAssertEqual(request["limit"] as? Int, 0, "limit 0 means the file to its end")
        XCTAssertEqual(request["synchronous"] as? Bool, true)
        XCTAssertEqual(fixture.transport.methods, ["getFile", "downloadFile"])
    }

    func testLocalFileURLRetriesAnIncompleteDownload() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let attempts = AttemptCounter()
        let fixture = ScriptedServiceFixture { request in
            guard request["@type"] as? String == "downloadFile" else {
                return .result(Self.downloadedFile(path: file.path, completed: false))
            }
            return .result(Self.downloadedFile(path: file.path, completed: attempts.next() >= 2))
        }
        defer { fixture.finish() }

        let url = try await fixture.service.localFileURL(fileId: "314")

        XCTAssertEqual(url.path, file.path)
        XCTAssertEqual(fixture.transport.requests(ofType: "downloadFile").count, 2)
    }

    func testDownloadedFileIsServedDuringAFloodWaitOnDownloads() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { _ in
            .result(Self.downloadedFile(path: file.path, completed: true))
        }
        defer { fixture.finish() }
        // An hour-long limit: a throttled downloadFile fails at once.
        await fixture.service.throttle.reportFloodWait(seconds: 3600, method: "downloadFile")

        let url = try await fixture.service.localFileURL(fileId: "314")

        XCTAssertEqual(url.path, file.path)
        XCTAssertEqual(fixture.transport.methods, ["getFile"],
                       "TDLib already holds the file: it needs no download request and no throttle slot")
    }

    func testDownloadedFileBytesAreReadWithoutADownloadRequest() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { _ in
            .result(Self.downloadedFile(path: file.path, completed: true))
        }
        defer { fixture.finish() }
        await fixture.service.throttle.reportFloodWait(seconds: 3600, method: "downloadFile")

        let data = try await fixture.service.downloadFile(fileId: "314")

        XCTAssertEqual(data, Data("whole file".utf8))
        XCTAssertEqual(fixture.transport.methods, ["getFile"])
    }

    func testPartlyDownloadedFileIsDownloadedThroughTheThrottle() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { request in
            .result(Self.downloadedFile(path: file.path, completed: request["@type"] as? String == "downloadFile"))
        }
        defer { fixture.finish() }
        await fixture.service.throttle.reportFloodWait(seconds: 3600, method: "downloadFile")

        do {
            _ = try await fixture.service.localFileURL(fileId: "314")
            XCTFail("A file TDLib has not finished must wait for the download limit")
        } catch let error as TDError {
            guard case .rateLimited = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(fixture.transport.methods, ["getFile"])
    }

    func testFileWhoseCopyIsGoneIsDownloadedAgain() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).bin")
        let fixture = ScriptedServiceFixture { request in
            // TDLib still lists the old copy until downloadFile checks it.
            let path = request["@type"] as? String == "getFile" ? missing.path : file.path
            return .result(Self.downloadedFile(path: path, completed: true))
        }
        defer { fixture.finish() }

        let url = try await fixture.service.localFileURL(fileId: "314")

        XCTAssertEqual(url.path, file.path)
        XCTAssertEqual(fixture.transport.methods, ["getFile", "downloadFile"])
    }

    func testDownloadedFileURLAnswersOnlyACompleteCopy() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { request in
            .result(Self.downloadedFile(path: file.path, completed: request["file_id"] as? Int == 314))
        }
        defer { fixture.finish() }
        await fixture.service.throttle.reportFloodWait(seconds: 3600, method: "downloadFile")

        let complete = await fixture.service.downloadedFileURL(fileId: "314")
        let partial = await fixture.service.downloadedFileURL(fileId: "315")
        let invalid = await fixture.service.downloadedFileURL(fileId: "0")

        XCTAssertEqual(complete?.path, file.path)
        XCTAssertNil(partial)
        XCTAssertNil(invalid)
        XCTAssertEqual(fixture.transport.methods, ["getFile", "getFile"], "It never starts a download")
    }

    // MARK: - Download priority, cancellation and stalls

    func testDownloadAsksForTheCallersPriority() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { request in
            .result(Self.downloadedFile(path: file.path, completed: request["@type"] as? String == "downloadFile"))
        }
        defer { fixture.finish() }

        _ = try await fixture.service.localFileURL(fileId: "314", priority: .offscreen)
        _ = try await fixture.service.localFileURL(fileId: "314", priority: .onScreen)

        let priorities = fixture.transport.requests(ofType: "downloadFile").map { $0["priority"] as? Int }
        XCTAssertEqual(priorities, [1, 16], "What is on screen downloads before what is not")
    }

    func testPriorityChangedBeforeTheDownloadIsSentIsTheOneSent() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture { request in
            guard request["@type"] as? String == "downloadFile" else {
                return .delayed(0.2, Self.downloadedFile(path: file.path, completed: false))
            }
            return .result(Self.downloadedFile(path: file.path, completed: true))
        }
        defer { fixture.finish() }
        let priority = DownloadPriorityHandle(.offscreen)

        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        try await waitUntil { fixture.transport.events.contains("-> getFile") }
        // The row scrolled into view while TDLib looked for a local copy.
        priority.update(.onScreen)
        _ = try await download.value

        let priorities = fixture.transport.requests(ofType: "downloadFile").map { $0["priority"] as? Int }
        XCTAssertEqual(priorities, [16])
    }

    func testPriorityChangedDuringTheThrottleWaitGoesOutWithTheRequest() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ThrottleClock()
        let fixture = ScriptedServiceFixture(
            requestThrottle: TDRequestThrottle(minSpacing: .zero, now: { clock.now }, sleep: { try await clock.sleep($0) })
        ) { request in
            .result(Self.downloadedFile(path: file.path, completed: request["@type"] as? String == "downloadFile"))
        }
        defer { fixture.finish() }
        await fixture.service.throttle.reportFloodWait(seconds: 1, method: "downloadFile")
        let priority = DownloadPriorityHandle(.offscreen)

        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        // The request is parked in the throttle until the test lets the limit pass.
        try await waitUntil { clock.sleepers == 1 }
        priority.update(.requested)
        clock.advance(by: .seconds(2))
        _ = try await download.value

        let priorities = fixture.transport.requests(ofType: "downloadFile").map { $0["priority"] as? Int }
        XCTAssertEqual(priorities, [32], "The request carries the priority of when it is sent, not of when it queued")
    }

    func testPriorityChangedDuringADownloadMovesIt() async throws {
        let fixture = ScriptedServiceFixture { request in
            if request["@type"] as? String == "downloadFile", request["synchronous"] as? Bool == true {
                return .silence
            }
            return .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
        }
        defer { fixture.finish() }
        let priority = DownloadPriorityHandle(.offscreen)
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        defer { download.cancel() }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }
        // The download is under way; moving it adds no server request.
        await fixture.service.throttle.reportFloodWait(seconds: 3600, method: "downloadFile")

        priority.update(.requested)
        try await waitUntil { fixture.transport.requests(ofType: "downloadFile").count == 2 }

        let move = try XCTUnwrap(fixture.transport.requests(ofType: "downloadFile").last)
        XCTAssertEqual(move["file_id"] as? Int, 314)
        XCTAssertEqual(move["priority"] as? Int, 32)
        XCTAssertEqual(move["synchronous"] as? Bool, false, "A second synchronous request would wait for nothing")
        XCTAssertEqual(move["offset"] as? Int, 0)
        XCTAssertEqual(move["limit"] as? Int, 0, "TDLib keeps the waiting request only for the same offset and limit")
    }

    func testPriorityHandleTellsEveryObserverUntilItIsRemoved() {
        let priority = DownloadPriorityHandle(.offscreen)
        let first = PriorityLog(), second = PriorityLog()
        let firstToken = priority.addObserver { first.append($0) }
        let secondToken = priority.addObserver { second.append($0) }

        priority.update(.onScreen)
        priority.update(.onScreen)
        priority.removeObserver(firstToken)
        priority.update(.requested)
        priority.removeObserver(secondToken)
        priority.update(.offscreen)

        XCTAssertEqual(first.values, [.onScreen])
        XCTAssertEqual(second.values, [.onScreen, .requested], "A request that ends must not stop another one's moves")
        XCTAssertEqual(priority.value, .offscreen)
    }

    func testUnchangedPriorityDoesNotMoveTheDownload() async throws {
        let fixture = ScriptedServiceFixture { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            return .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
        }
        defer { fixture.finish() }
        let priority = DownloadPriorityHandle(.onScreen)
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        defer { download.cancel() }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }

        priority.update(.onScreen)
        // A real change after the unchanged one: moves go out in the order they were made.
        priority.update(.requested)
        try await waitUntil { fixture.transport.requests(ofType: "downloadFile").count == 2 }

        let priorities = fixture.transport.requests(ofType: "downloadFile").map { $0["priority"] as? Int }
        XCTAssertEqual(priorities, [16, 32], "Telling TDLib the priority it already has is a request for nothing")
    }

    /// TDLib keeps the priority of the last request it reads, so requests
    /// about one download that overtake each other leave it on a stale one.
    func testMovesReachTDLibOneAtATimeInTheOrderTheyWereMade() async throws {
        let moves = AttemptCounter()
        let fixture = ScriptedServiceFixture { request in
            guard request["@type"] as? String == "downloadFile" else {
                return .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
            }
            if request["synchronous"] as? Bool == true { return .silence }
            // The first move is answered late: the second is decided while it is in flight.
            let answer = Self.downloadedFile(path: "/tmp/partial", completed: false)
            return moves.next() == 1 ? .delayed(0.5, answer) : .result(answer)
        }
        defer { fixture.finish() }
        let priority = DownloadPriorityHandle(.onScreen)
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        defer { download.cancel() }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }

        priority.update(.offscreen)
        try await waitUntil { fixture.transport.requests(ofType: "downloadFile").count == 2 }
        priority.update(.requested)
        try await waitUntil(timeout: .seconds(5)) {
            fixture.transport.events.filter { $0 == "<- downloadFile" }.count == 2
        }

        let priorities = fixture.transport.requests(ofType: "downloadFile").map { $0["priority"] as? Int }
        XCTAssertEqual(priorities, [16, 1, 32])
        XCTAssertEqual(fixture.transport.events.filter { $0.hasSuffix("downloadFile") },
                       ["-> downloadFile", "-> downloadFile", "<- downloadFile", "-> downloadFile", "<- downloadFile"],
                       "The second move was sent before TDLib answered the first")
    }

    func testMoveQueuedBehindAnotherIsDroppedOnceTheDownloadEnded() async throws {
        let moves = AttemptCounter()
        let fixture = ScriptedServiceFixture { request in
            guard request["@type"] as? String == "downloadFile" else {
                return .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
            }
            if request["synchronous"] as? Bool == true { return .silence }
            return .delayed(moves.next() == 1 ? 0.3 : 0, Self.downloadedFile(path: "/tmp/partial", completed: false))
        }
        defer { fixture.finish() }
        let priority = DownloadPriorityHandle(.onScreen)
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: priority) }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }
        priority.update(.offscreen)
        try await waitUntil { fixture.transport.requests(ofType: "downloadFile").count == 2 }

        // The second move waits behind the first; the chat closes before its turn.
        priority.update(.requested)
        download.cancel()
        _ = await download.result

        try await waitUntil(timeout: .seconds(5)) { !fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty }
        let moveAfterTheEnd = fixture.transport.requests(ofType: "downloadFile").count
        XCTAssertEqual(moveAfterTheEnd, 2, "A move sent after the download ended starts it again for nobody")
        XCTAssertEqual(fixture.transport.methods.last, "cancelDownloadFile")
    }

    func testCancellingTheCallerStopsTheTDLibDownload() async throws {
        let fixture = ScriptedServiceFixture { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            return .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
        }
        defer { fixture.finish() }
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: .onScreen) }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }

        download.cancel()

        do {
            _ = try await download.value
            XCTFail("A cancelled download must not report a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        try await waitUntil { !fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty }
        let cancel = try XCTUnwrap(fixture.transport.requests(ofType: "cancelDownloadFile").first)
        XCTAssertEqual(cancel["file_id"] as? Int, 314)
        XCTAssertEqual(cancel["only_if_pending"] as? Bool, false, "A download already under way must stop as well")
    }

    func testDownloadThatKeepsProgressingOutlivesTheStallTimeout() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let polls = AttemptCounter()
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(200), downloadProgressInterval: .milliseconds(40)
        ) { request in
            guard request["@type"] as? String == "downloadFile" else {
                return .result(Self.partialFile(downloaded: Int64(polls.next())))
            }
            return .delayed(0.6, Self.downloadedFile(path: file.path, completed: true))
        }
        defer { fixture.finish() }

        let url = try await fixture.service.localFileURL(fileId: "314", priority: .onScreen)

        XCTAssertEqual(url.path, file.path, "A slow download that keeps going must not be cut off")
        XCTAssertTrue(fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty)
    }

    func testDownloadWithoutProgressFailsAndStops() async throws {
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(200), downloadProgressInterval: .milliseconds(40)
        ) { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            return .result(Self.partialFile(downloaded: 4))
        }
        defer { fixture.finish() }

        do {
            _ = try await fixture.service.localFileURL(fileId: "314", priority: .onScreen)
            XCTFail("A download that gains nothing must fail like the request timeout did")
        } catch TDError.timeout {
            // Expected.
        }
        try await waitUntil { !fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty }
    }

    func testDownloadQueuedBehindAnotherIsNotCutOffWhileThatOneKeepsGoing() async throws {
        let busy = ProgressScript()
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(400), downloadProgressInterval: .milliseconds(40)
        ) { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            // TDLib hands its download budget out by priority: file 315 gets nothing until 314 is done.
            let fileId = request["file_id"] as? Int ?? 0
            return .result(Self.partialFile(id: fileId, downloaded: fileId == 314 ? busy.nextSize() : 4))
        }
        defer { fixture.finish() }
        let first = Task { try await fixture.service.localFileURL(fileId: "314", priority: .requested) }
        let queued = Task { try await fixture.service.localFileURL(fileId: "315", priority: .offscreen) }
        defer {
            first.cancel()
            queued.cancel()
        }
        try await waitUntil { fixture.transport.requests(ofType: "downloadFile").count == 2 }

        // Four stall timeouts of the busy download's polls.
        try await waitUntil(timeout: .seconds(10)) { busy.polls >= 40 }

        XCTAssertTrue(fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty,
                      "A download that waits behind another is queued, not stalled")
        // Now the busy download stops gaining bytes too: nothing moves any more.
        busy.stop()
        for task in [first, queued] {
            do {
                _ = try await task.value
                XCTFail("A transport where nothing gains bytes must fail its downloads")
            } catch TDError.timeout {
                // Expected.
            }
        }
        // A download stops behind the requests already made about it, so its
        // cancel can follow the error its caller got.
        let cancelled = { Set(fixture.transport.requests(ofType: "cancelDownloadFile").compactMap { $0["file_id"] as? Int }) }
        try await waitUntil { cancelled().count == 2 }
        XCTAssertEqual(cancelled(), [314, 315])
    }

    func testDownloadIsNotCutOffWhenItsProgressCheckFails() async throws {
        let file = try Self.makeDownloadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(200), downloadProgressInterval: .milliseconds(40)
        ) { request in
            // TDLib is busy or waking up: the offline getFile fails, the download goes on.
            guard request["@type"] as? String == "downloadFile" else { return .error(code: 500, message: "busy") }
            return .delayed(0.8, Self.downloadedFile(path: file.path, completed: true))
        }
        defer { fixture.finish() }

        do {
            let url = try await fixture.service.localFileURL(fileId: "314", priority: .onScreen)
            XCTAssertEqual(url.path, file.path)
        } catch {
            XCTFail("A check that got no answer says nothing about the download, yet it failed: \(error)")
        }
        XCTAssertTrue(fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty)
    }

    func testPausedTransportIsNotWatchedForStalls() async throws {
        let fixture = ScriptedServiceFixture(
            downloadStallTimeout: .milliseconds(600), downloadProgressInterval: .milliseconds(200)
        ) { request in
            if request["@type"] as? String == "downloadFile" { return .silence }
            return .result(Self.partialFile(downloaded: 4))
        }
        defer { fixture.finish() }
        let download = Task { try await fixture.service.localFileURL(fileId: "314", priority: .onScreen) }
        defer { download.cancel() }
        try await waitUntil { fixture.transport.events.contains("-> downloadFile") }

        // The wrist went down: the client stops reading what TDLib answers, and
        // the first check is still a whole interval away.
        fixture.client.pause()
        let checksBefore = fixture.transport.requests(ofType: "getFile").count
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fixture.transport.requests(ofType: "getFile").count, checksBefore,
                       "Every check of a paused client waits out its request timeout for nothing")
        XCTAssertTrue(fixture.transport.requests(ofType: "cancelDownloadFile").isEmpty)
        // Back on the wrist the download is watched again.
        fixture.client.resume()
        do {
            _ = try await download.value
            XCTFail("A download that gains nothing must fail")
        } catch TDError.timeout {
            // Expected.
        }
    }

    func testCancelledDownloadStopsInsteadOfRetrying() async throws {
        // An hour between attempts: the cancel lands while the service waits to retry.
        let fixture = ScriptedServiceFixture(downloadRetryDelay: .seconds(3600)) { _ in
            .result(Self.downloadedFile(path: "/tmp/partial", completed: false))
        }
        defer { fixture.finish() }

        let download = Task { try await fixture.service.localFileURL(fileId: "314") }
        // The first attempt answers "incomplete" and the service waits to retry.
        try await waitUntil { fixture.transport.events.contains("<- downloadFile") }
        download.cancel()

        do {
            _ = try await download.value
            XCTFail("A cancelled download must not report a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(fixture.transport.requests(ofType: "downloadFile").count, 1,
                       "No further attempt may start after the caller cancelled")
    }

    // MARK: - Voice upload

    func testSendVoiceLeavesTheUploadFileForTDLibToFinish() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let recording = Data("voice-recording".utf8)

        let message = try await fixture.service.sendVoice(chatId: 42, data: recording, duration: 3)

        XCTAssertEqual(message.id, 1001)
        let request = try XCTUnwrap(fixture.transport.requests(ofType: "sendMessage").first)
        let path = try Self.voiceNotePath(in: request)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // sendMessage returns a pending message; TDLib uploads the file afterwards.
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), recording,
                       "The upload file was removed while TDLib still needs it")
        // In Application Support with the database, not in tmp, which the
        // system may purge before the upload ends.
        XCTAssertTrue(path.hasPrefix(fixture.directory.standardizedFileURL.path + "/"),
                      "The copy at \(path) is outside the database directory")
    }

    func testSendVoiceRemovesTheUploadFileWhenTDLibRejectsTheSend() async throws {
        let fixture = ScriptedServiceFixture { _ in .error(code: 400, message: "CHAT_WRITE_FORBIDDEN") }
        defer { fixture.finish() }

        do {
            _ = try await fixture.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
            XCTFail("A rejected send must throw")
        } catch let error as TDError {
            guard case .api(_, let message) = error else { return XCTFail("Unexpected error \(error)") }
            XCTAssertEqual(message, "CHAT_WRITE_FORBIDDEN")
        }

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "sendMessage").first)
        let path = try Self.voiceNotePath(in: request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "A rejected send leaks its upload file")
    }

    func testSendVoiceRemovesUploadFilesOlderThanTheRetention() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let directory = fixture.service.voiceUploadDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = directory.appendingPathComponent("expired-\(UUID().uuidString).m4a")
        let recent = directory.appendingPathComponent("recent-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: expired)
            try? FileManager.default.removeItem(at: recent)
        }
        for url in [expired, recent] { try Data("old upload".utf8).write(to: url) }
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: expired.path)

        _ = try await fixture.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
        if let request = fixture.transport.requests(ofType: "sendMessage").first,
           let path = try? Self.voiceNotePath(in: request) {
            try? FileManager.default.removeItem(atPath: path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path),
                       "Uploads nobody will retry pile up in Application Support")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path),
                      "A recent upload may still be in flight")
    }

    // MARK: - Fixtures

    private static var sentMessage: [String: Any] {
        [
            "@type": "message", "id": Int64(1001), "chat_id": Int64(42),
            "date": 1_700_000_000, "is_outgoing": true,
            "sender_id": ["@type": "messageSenderUser", "user_id": Int64(7)],
            "content": ["@type": "messageText",
                        "text": ["@type": "formattedText", "text": "voice", "entities": []]]
        ]
    }

    private static func makeDownloadFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).bin")
        try Data("whole file".utf8).write(to: file)
        return file
    }

    private static func partialFile(id: Int = 314, downloaded: Int64) -> [String: Any] {
        [
            "@type": "file", "id": id, "size": 1000, "expected_size": 1000,
            "local": ["@type": "localFile", "path": "/tmp/partial", "is_downloading_active": true,
                      "is_downloading_completed": false, "downloaded_size": downloaded]
        ]
    }

    private static func downloadedFile(path: String, completed: Bool) -> [String: Any] {
        [
            "@type": "file", "id": 314, "size": 10, "expected_size": 10,
            "local": ["@type": "localFile", "path": path,
                      "is_downloading_completed": completed, "downloaded_size": completed ? 10 : 4]
        ]
    }

    private static func voiceNotePath(in request: [String: Any]) throws -> String {
        let content = try XCTUnwrap(request["input_message_content"] as? [String: Any])
        XCTAssertEqual(content["@type"] as? String, "inputMessageVoiceNote")
        let voiceNote = try XCTUnwrap(content["voice_note"] as? [String: Any])
        XCTAssertEqual(voiceNote["@type"] as? String, "inputFileLocal")
        return try XCTUnwrap(voiceNote["path"] as? String)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the request") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class PriorityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [DownloadPriority] = []

    var values: [DownloadPriority] { lock.withLock { log } }

    func append(_ priority: DownloadPriority) {
        lock.withLock { log.append(priority) }
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 1 for the first call, 2 for the second, and so on.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// getFile answers of a download that gains bytes at every check until it is
/// told to stop.
private final class ProgressScript: @unchecked Sendable {
    private let lock = NSLock()
    private var size: Int64 = 0
    private var isStopped = false
    private var pollCount = 0

    /// How many times the download was checked.
    var polls: Int { lock.withLock { pollCount } }

    func nextSize() -> Int64 {
        lock.withLock {
            pollCount += 1
            if !isStopped { size += 1 }
            return size
        }
    }

    func stop() {
        lock.withLock { isStopped = true }
    }
}

/// A throttle clock the test controls: a wait lasts until the test advances
/// the time, however long the machine takes.
private final class ThrottleClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed = Duration.zero
    private var waiting = 0

    var now: ContinuousClock.Instant {
        lock.withLock { start + elapsed }
    }

    /// How many waits are parked.
    var sleepers: Int {
        lock.withLock { waiting }
    }

    func sleep(_ duration: Duration) async throws {
        let wakeTime = lock.withLock {
            waiting += 1
            return start + elapsed + duration
        }
        defer { lock.withLock { waiting -= 1 } }
        while now < wakeTime {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }
}
