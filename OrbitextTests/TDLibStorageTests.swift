import Synchronization
import XCTest
@testable import OrbitextWatch

/// The transport's files on the device: what Clear cache asks TDLib to
/// delete and how long the copies of sent voice notes stay, observed
/// through a scripted TDLib client.
final class TDLibStorageTests: XCTestCase {
    // MARK: - Clear cache

    func testClearFileCacheAsksTDLibToDeleteEveryDownloadedFileNow() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.storageStatistics) }
        defer { fixture.finish() }

        try await fixture.service.clearFileCache()

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "optimizeStorage").first)
        XCTAssertEqual(fixture.transport.requests(ofType: "optimizeStorage").count, 1)
        // -1 would mean TDLib's own limits: 100 MB, 23 hours since the last
        // access, and an hour during which a new file is kept.
        XCTAssertEqual(request["size"] as? Int, 0)
        XCTAssertEqual(request["ttl"] as? Int, 0)
        XCTAssertEqual(request["count"] as? Int, 0)
        XCTAssertEqual((request["chat_ids"] as? [Any])?.count, 0, "Files of every chat")
        XCTAssertEqual((request["exclude_chat_ids"] as? [Any])?.count, 0)
        XCTAssertEqual(request["chat_limit"] as? Int, 0)
    }

    /// TDLib files a partial download in its temp directory under the real
    /// type recorded in the file database, and a running download rewrites it
    /// all the time. With no immunity the clean-up unlinks it under the
    /// downloader (TDLib is not told: it only unlinks Full locations), and the
    /// download never finishes.
    func testClearFileCacheKeepsFilesWrittenInTheLastMinute() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.storageStatistics) }
        defer { fixture.finish() }

        try await fixture.service.clearFileCache()

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "optimizeStorage").first)
        let delay = try XCTUnwrap(request["immunity_delay"] as? Int)
        XCTAssertGreaterThanOrEqual(delay, 60, "A file written seconds ago is a download in progress")
        XCTAssertLessThanOrEqual(delay, 120, "Clear cache should still delete what was viewed a couple of minutes ago")
    }

    /// optimizeStorage scans every file and then unlinks them all: the time
    /// grows with the cache, which is when someone taps Clear cache. A timeout
    /// reports a failure while TDLib is still deleting, and the next tap
    /// makes TDLib abort the run and start the scan over.
    func testClearFileCacheWaitsForTDLibBeyondTheRequestTimeout() async throws {
        let fixture = ScriptedServiceFixture(requestTimeout: .milliseconds(100)) { request in
            request["@type"] as? String == "optimizeStorage" ? .delayed(0.5, Self.storageStatistics) : .result(["@type": "ok"])
        }
        defer { fixture.finish() }

        try await fixture.service.clearFileCache()

        XCTAssertEqual(fixture.transport.requests(ofType: "optimizeStorage").count, 1)
    }

    func testClearFileCacheNamesTheTypesTDLibKeepsByDefault() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.storageStatistics) }
        defer { fixture.finish() }

        try await fixture.service.clearFileCache()

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "optimizeStorage").first)
        let types = try Set(XCTUnwrap(request["file_types"] as? [[String: Any]]).compactMap { $0["@type"] as? String })
        // With an empty list TDLib skips these, and its daily clean-up never
        // deletes them: they pile up for the life of the account.
        for kept in ["fileTypeSticker", "fileTypeProfilePhoto", "fileTypeThumbnail", "fileTypeWallpaper",
                     "fileTypeNotificationSound"] {
            XCTAssertTrue(types.contains(kept), "\(kept) stays on the watch")
        }
        for media in ["fileTypePhoto", "fileTypeVideo", "fileTypeVideoNote", "fileTypeVoiceNote", "fileTypeAudio",
                      "fileTypeAnimation", "fileTypeDocument"] {
            XCTAssertTrue(types.contains(media), "\(media) stays on the watch")
        }
        XCTAssertFalse(types.contains("fileTypeUnknown"), "TDLib's temp files carry no type of their own")
    }

    func testClearFileCacheReportsATDLibError() async throws {
        let fixture = ScriptedServiceFixture { _ in .error(code: 500, message: "Request aborted") }
        defer { fixture.finish() }

        do {
            try await fixture.service.clearFileCache()
            XCTFail("A failed optimizeStorage must not look like a cleared cache")
        } catch let error as TDError {
            guard case .api(let code, _) = error else { return XCTFail("Unexpected error \(error)") }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Copies of sent voice notes

    func testSendVoiceKeepsTheCopyWithTheSessionsDatabase() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }

        _ = try await fixture.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)

        let path = try Self.voiceNotePath(in: XCTUnwrap(fixture.transport.requests(ofType: "sendMessage").first))
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Settings counts that directory as the cache, and the session's wipe
        // deletes it.
        XCTAssertTrue(path.hasPrefix(fixture.directory.standardizedFileURL.path + "/"),
                      "The copy at \(path) is outside the database directory")
    }

    func testLogoutDeletesTheCopiesOfSentVoiceNotes() async throws {
        let session = try ScriptedSession { _ in .result(Self.sentMessage) }
        defer { session.finish() }
        _ = try await session.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
        let path = try Self.voiceNotePath(in: XCTUnwrap(session.transport.requests(ofType: "sendMessage").first))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        session.closeClient()

        try await session.service.completeLocalLogoutCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "The previous account's outgoing audio stays on the watch after logout")
    }

    func testLogoutForgetsWhichNotesWerePending() async throws {
        let session = try ScriptedSession { _ in .result(Self.sentMessage) }
        defer { session.finish() }
        _ = try await session.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
        let request = try XCTUnwrap(session.transport.requests(ofType: "sendMessage").first)
        let name = try URL(fileURLWithPath: Self.voiceNotePath(in: request)).lastPathComponent
        XCTAssertNotNil(session.service.voiceUploads.entry(for: name))
        session.closeClient()

        try await session.service.completeLocalLogoutCleanup()

        XCTAssertNil(session.service.voiceUploads.entry(for: name), "The next account inherits the record")
    }

    func testLogoutDeletesTheCopiesAnEarlierVersionKeptOutsideTheDatabase() async throws {
        let session = try ScriptedSession()
        defer { session.finish() }
        let legacy = try Self.makeUpload(in: TDLibService.legacyVoiceUploadDirectory, age: 0)
        defer { try? FileManager.default.removeItem(at: legacy) }
        session.closeClient()

        try await session.service.completeLocalLogoutCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testStartDeletesCopiesOlderThanAWeek() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The key lookup fails, so the start ends before a native client exists.
        let service = TDLibService(
            databaseDirectory: directory,
            apiCredentials: (id: 1, hash: "offline-test"),
            resolveDatabaseKey: { _ in throw TestError.failed("no key in this test") },
            removeDatabaseKey: {}
        )
        let week = 7 * 24 * 60 * 60.0
        let expired = try Self.makeUpload(in: service.voiceUploadDirectory, age: week + 60)
        let recent = try Self.makeUpload(in: service.voiceUploadDirectory, age: week - 60)
        let legacyExpired = try Self.makeUpload(in: TDLibService.legacyVoiceUploadDirectory, age: week + 60)
        defer { try? FileManager.default.removeItem(at: legacyExpired) }

        await service.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path),
                       "Without a later voice note nothing ever deleted the copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyExpired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path),
                      "TDLib resends a pending voice note after a restart and needs its file")
    }

    /// Nothing in this version writes to the folder earlier versions used, so
    /// whatever is there is a previous session's audio. When a logout could not
    /// remove it, the next start must not wait for the copy to turn a week old.
    func testStartRetriesRemovingTheCopiesAnEarlierVersionLeft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The key lookup fails, so the start ends before a native client exists.
        let service = TDLibService(
            databaseDirectory: directory,
            apiCredentials: (id: 1, hash: "offline-test"),
            resolveDatabaseKey: { _ in throw TestError.failed("no key in this test") },
            removeDatabaseKey: {}
        )
        let legacy = try Self.makeUpload(in: TDLibService.legacyVoiceUploadDirectory, age: 60)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path)
            try? FileManager.default.removeItem(at: legacy)
        }
        // A file the system will not let go of, as when a logout's removal failed.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: legacy.path)
        service.removeLegacyVoiceUploads()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "The removal was meant to fail")
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path)

        await service.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "The previous account's recent audio waits for the weekly sweep")
    }

    func testClearFileCacheDeletesTheCopiesOfVoiceNotesTDLibIsDoneWith() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let hour = 60 * 60.0
        // A copy no message needs: sent in an earlier session, or in a build
        // that kept no record.
        let unrecorded = try Self.makeUpload(in: fixture.service.voiceUploadDirectory, age: 60)
        let legacy = try Self.makeUpload(in: TDLibService.legacyVoiceUploadDirectory, age: hour + 60)
        defer { try? FileManager.default.removeItem(at: legacy) }

        try await fixture.service.clearFileCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: unrecorded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    /// sendMessage returns as soon as TDLib accepts the pending message. A
    /// note sent offline stays pending for hours and uploads from this file
    /// when the connection returns, so the age of the copy says nothing.
    func testClearFileCacheKeepsTheCopyOfAVoiceNoteStillSendingWhateverItsAge() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        try await fixture.service.clearFileCache()

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path),
                      "Clear cache deleted the file TDLib will upload when the watch is online again")
    }

    func testTheCopyOfASentVoiceNoteGoesWithClearCacheOnceTDLibDelivered() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        fixture.service.handleUpdate(Self.sendResult("updateMessageSendSucceeded", newMessageId: 2002))
        try await fixture.service.clearFileCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testTheCopyOfAVoiceNoteThatFailedToSendGoesWithClearCache() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        fixture.service.handleUpdate(Self.sendResult("updateMessageSendFailed", newMessageId: 1001))
        try await fixture.service.clearFileCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testTheCopyOfAPendingVoiceNoteTheUserDeletedGoesWithClearCache() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        fixture.service.handleUpdate([
            "@type": "updateDeleteMessages", "chat_id": Int64(42), "message_ids": [Int64(1001)],
            "is_permanent": true, "from_cache": false
        ])
        try await fixture.service.clearFileCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testAnEvictedMessageDoesNotReleaseTheCopyOfAPendingVoiceNote() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        // TDLib drops the message from its cache only; it is still pending.
        fixture.service.handleUpdate([
            "@type": "updateDeleteMessages", "chat_id": Int64(42), "message_ids": [Int64(1001)],
            "is_permanent": false, "from_cache": true
        ])
        try await fixture.service.clearFileCache()

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    /// The watch is offline for hours, and watchOS relaunches the app many
    /// times in them: the pending state has to survive the process.
    func testTheCopyOfAPendingVoiceNoteStaysProtectedAfterARestart() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)
        let relaunched = TDLibService(databaseDirectory: fixture.directory)

        relaunched.removeVoiceUploads(olderThan: 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "A relaunch forgot which notes are pending")

        relaunched.handleUpdate(Self.sendResult("updateMessageSendSucceeded", newMessageId: 2002))
        relaunched.removeVoiceUploads(olderThan: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "TDLib delivered the note after the relaunch")
    }

    /// The update can be handled before the task that called sendVoice resumes
    /// with the message.
    func testTheCopyIsReleasedWhenTDLibDeliveredBeforeSendVoiceHadTheMessage() async throws {
        let service = Mutex<TDLibService?>(nil)
        let fixture = ScriptedServiceFixture { request in
            if request["@type"] as? String == "sendMessage" {
                service.withLock { $0 }?.handleUpdate(Self.sendResult("updateMessageSendSucceeded", newMessageId: 2002))
            }
            return .result(Self.sentMessage)
        }
        defer { fixture.finish() }
        service.withLock { $0 = fixture.service }
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: 3 * 60 * 60)

        try await fixture.service.clearFileCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "The note was delivered; nothing will release the copy")
    }

    /// A kill between writing the copy and sendMessage returning leaves a copy
    /// with no message. It cannot be pending in TDLib, but a note being sent
    /// right now looks the same, so only a copy past the hour is abandoned.
    func testClearFileCacheKeepsACopyBeingSentAndDeletesOneAbandonedBeforeItsMessageExisted() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.storageStatistics) }
        defer { fixture.finish() }
        let inFlight = try fixture.service.prepareVoiceUploadFile(Data("voice".utf8))
        let abandoned = try fixture.service.prepareVoiceUploadFile(Data("voice".utf8))
        try Self.setAge(2 * 60 * 60, of: abandoned)

        try await fixture.service.clearFileCache()

        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path), "sendMessage has not returned yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testStartKeepsTheCopyOfAVoiceNoteStillPendingAfterAWeek() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let week = 7 * 24 * 60 * 60.0
        let pending = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: week + 60)
        let unrecorded = try Self.makeUpload(in: fixture.service.voiceUploadDirectory, age: week + 60)
        let relaunched = TDLibService(
            databaseDirectory: fixture.directory,
            apiCredentials: (id: 1, hash: "offline-test"),
            resolveDatabaseKey: { _ in throw TestError.failed("no key in this test") },
            removeDatabaseKey: {}
        )

        await relaunched.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "TDLib has not delivered that note yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrecorded.path))
    }

    /// A lost update (the app was killed after TDLib delivered, before the
    /// app recorded it) must not keep the audio for ever.
    func testAPendingCopyIsDeletedOnceItIsOlderThanAMonth() async throws {
        let fixture = ScriptedServiceFixture { _ in .result(Self.sentMessage) }
        defer { fixture.finish() }
        let month = 30 * 24 * 60 * 60.0
        let copy = try await Self.sendVoice(through: fixture.service, transport: fixture.transport, copyAge: month + 60)

        fixture.service.removeVoiceUploads(olderThan: TDLibService.voiceUploadRetention)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testAFailedSendRemovesTheCopyAndItsRecord() async throws {
        let fixture = ScriptedServiceFixture { _ in .error(code: 400, message: "CHAT_WRITE_FORBIDDEN") }
        defer { fixture.finish() }

        do {
            _ = try await fixture.service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
            XCTFail("The scripted client refuses the message")
        } catch {}

        let copies = try? FileManager.default.contentsOfDirectory(atPath: fixture.service.voiceUploadDirectory.path)
        XCTAssertEqual(copies?.filter { $0.hasSuffix(".m4a") }, [])
    }

    // MARK: - Fixtures

    private static var storageStatistics: [String: Any] {
        ["@type": "storageStatistics", "size": 0, "count": 0, "by_chat": [Any]()]
    }

    private static var sentMessage: [String: Any] {
        [
            "@type": "message", "id": Int64(1001), "chat_id": Int64(42),
            "date": 1_700_000_000, "is_outgoing": true,
            "sender_id": ["@type": "messageSenderUser", "user_id": Int64(7)],
            "content": ["@type": "messageText",
                        "text": ["@type": "formattedText", "text": "voice", "entities": []]]
        ]
    }

    /// An update of the kind TDLib sends when it is done with the message
    /// sendMessage returned as 1001.
    private static func sendResult(_ type: String, newMessageId: Int64) -> [String: Any] {
        var message = sentMessage
        message["id"] = newMessageId
        return ["@type": type, "old_message_id": Int64(1001), "message": message]
    }

    /// Sends a voice note and returns its copy, aged `copyAge` seconds.
    private static func sendVoice(
        through service: TDLibService, transport: ScriptedTDTransport, copyAge: TimeInterval
    ) async throws -> URL {
        _ = try await service.sendVoice(chatId: 42, data: Data("voice".utf8), duration: 3)
        let request = try XCTUnwrap(transport.requests(ofType: "sendMessage").last)
        let copy = try URL(fileURLWithPath: voiceNotePath(in: request))
        try setAge(copyAge, of: copy)
        return copy
    }

    private static func setAge(_ age: TimeInterval, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private static func voiceNotePath(in request: [String: Any]) throws -> String {
        let content = try XCTUnwrap(request["input_message_content"] as? [String: Any])
        let voiceNote = try XCTUnwrap(content["voice_note"] as? [String: Any])
        return try XCTUnwrap(voiceNote["path"] as? String)
    }

    /// An upload copy last written `age` seconds ago.
    private static func makeUpload(in directory: URL, age: TimeInterval) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("upload".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
}

/// A `TDLibService` on a scripted client whose session a test can wipe:
/// unlike `ScriptedServiceFixture`, the wipe leaves the Keychain alone.
private final class ScriptedSession: Sendable {
    let service: TDLibService
    let transport: ScriptedTDTransport
    let directory: URL
    private let client: TDJsonWrapper

    init(script: @escaping ScriptedTDTransport.Script = { _ in .result(["@type": "ok"]) }) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripted-session-\(UUID().uuidString)", isDirectory: true)
        service = TDLibService(
            databaseDirectory: directory,
            requestThrottle: TDRequestThrottle(minSpacing: .zero),
            removeDatabaseKey: {}
        )
        transport = ScriptedTDTransport(script: script)
        client = transport.wrapper()
        service.session.replaceClientForTesting(client)
        client.startReceiveLoop { _ in }
    }

    /// As once TDLib has confirmed its close: nothing of the session is in use.
    func closeClient() {
        service.session.replaceClientForTesting(nil)
        client.stop()
    }

    func finish() {
        closeClient()
        try? FileManager.default.removeItem(at: directory)
    }
}
