import SwiftUI
import XCTest
@testable import OrbitextWatch

/// Self-destructing media (Telegram API Terms of Service 1.4): the message
/// says how its media destroys itself, a destroyed one arrives as expired
/// content, and none of its files outlives the viewer that opened it.
@MainActor
final class SelfDestructMediaTests: XCTestCase {
    // MARK: - Mapping

    func testTimerSelfDestructTypeBecomesATimerPolicy() throws {
        let info = try XCTUnwrap(TDLibService().parseMessageInfo(Self.message(
            content: Self.photoContent,
            selfDestructType: ["@type": "messageSelfDestructTypeTimer", "self_destruct_time": 10]
        )))

        XCTAssertEqual(info.selfDestruct, .timer(seconds: 10))
        XCTAssertTrue(info.isSelfDestructingMedia)
    }

    func testImmediatelySelfDestructTypeIsViewOnce() throws {
        let info = try XCTUnwrap(TDLibService().parseMessageInfo(Self.message(
            content: Self.voiceContent,
            selfDestructType: ["@type": "messageSelfDestructTypeImmediately"]
        )))

        XCTAssertEqual(info.selfDestruct, .viewOnce)
        XCTAssertTrue(info.isSelfDestructingMedia)
    }

    func testMessageWithoutSelfDestructTypeKeepsItsMedia() throws {
        let info = try XCTUnwrap(TDLibService().parseMessageInfo(Self.message(content: Self.photoContent)))

        XCTAssertNil(info.selfDestruct)
        XCTAssertFalse(info.isSelfDestructingMedia)
    }

    func testTextWithASelfDestructTypeIsNoSelfDestructingMedia() throws {
        let info = try XCTUnwrap(TDLibService().parseMessageInfo(Self.message(
            content: ["@type": "messageText", "text": ["text": "hi"] as [String: Any]],
            selfDestructType: ["@type": "messageSelfDestructTypeImmediately"]
        )))

        XCTAssertEqual(info.selfDestruct, .viewOnce)
        XCTAssertFalse(info.isSelfDestructingMedia, "Only media is opened behind a placeholder")
    }

    func testExpiredContentMapsToExpiredMediaOfItsKind() {
        let expected: [(String, ExpiredMediaKind)] = [
            ("messageExpiredPhoto", .photo),
            ("messageExpiredVideo", .video),
            ("messageExpiredVideoNote", .videoNote),
            ("messageExpiredVoiceNote", .voiceNote)
        ]
        for (tag, kind) in expected {
            let content = MessageContent(tdApi: TDApi.decodeMessageContent(["@type": tag]))
            XCTAssertEqual(content, .expiredMedia(kind), tag)
            XCTAssertFalse(content.textPreview.isEmpty, tag)
            XCTAssertFalse(content.contentHandlesTap, "\(tag) has nothing left to open")
        }
    }

    func testSelfDestructPolicySurvivesASnapshot() throws {
        var message = MessageInfo(
            id: 1, chatId: 2, senderName: "A", senderId: 3, content: .expiredMedia(.video),
            date: Date(timeIntervalSince1970: 0), isOutgoing: false, isRead: false
        )
        message.selfDestruct = .timer(seconds: 30)

        let decoded = try JSONDecoder().decode(MessageInfo.self, from: JSONEncoder().encode(message))

        XCTAssertEqual(decoded.selfDestruct, .timer(seconds: 30))
        XCTAssertEqual(decoded.content, .expiredMedia(.video))
    }

    func testMediaFileIdsNameEveryFileOfTheContent() {
        let photo = MessageContent.photo(
            caption: .empty, fileId: "10", width: 1, height: 1, minithumbnail: nil, previewFileId: "11"
        )
        let video = MessageContent.video(
            caption: .empty, fileId: "20", thumbnailId: "21", width: 1, height: 1, duration: 3, minithumbnail: nil
        )
        XCTAssertEqual(photo.mediaFileIds, ["10", "11"])
        XCTAssertEqual(video.mediaFileIds, ["20", "21"])
        XCTAssertEqual(MessageContent.voice(duration: 2, fileId: "30", waveform: nil).mediaFileIds, ["30"])
        XCTAssertEqual(
            MessageContent.videoNote(duration: 2, fileId: "40", thumbnailId: nil, minithumbnail: nil).mediaFileIds,
            ["40"]
        )
        XCTAssertEqual(MessageContent.text("x").mediaFileIds, [])
    }

    func testExpiredKindFollowsTheMediaItReplaces() {
        XCTAssertEqual(
            MessageContent.photo(caption: .empty, fileId: "1", width: 1, height: 1, minithumbnail: nil).expiredKind,
            .photo
        )
        XCTAssertEqual(MessageContent.voice(duration: 1, fileId: "1", waveform: nil).expiredKind, .voiceNote)
        XCTAssertNil(MessageContent.text("x").expiredKind)
    }

    // MARK: - Viewing time

    func testViewOncePhotoStaysUntilClosed() {
        XCTAssertNil(SelfDestructPolicy.viewOnce.viewingTime(mediaDuration: nil))
    }

    func testViewOnceMediaThatPlaysClosesWhenItHasPlayedOnce() {
        let slack = SelfDestructPolicy.playbackSlack
        XCTAssertEqual(SelfDestructPolicy.viewOnce.viewingTime(mediaDuration: 7), .seconds(7 + slack))
    }

    func testTimerBoundsTheViewingButNeverCutsPlaybackShort() {
        let slack = SelfDestructPolicy.playbackSlack
        XCTAssertEqual(SelfDestructPolicy.timer(seconds: 10).viewingTime(mediaDuration: nil), .seconds(10))
        XCTAssertEqual(SelfDestructPolicy.timer(seconds: 10).viewingTime(mediaDuration: 3), .seconds(10))
        XCTAssertEqual(SelfDestructPolicy.timer(seconds: 5).viewingTime(mediaDuration: 30), .seconds(30 + slack))
        XCTAssertEqual(SelfDestructPolicy.timer(seconds: 0).viewingTime(mediaDuration: nil), .seconds(1))
    }

    func testPlaybackDurationIsTheLengthOfMediaThatPlays() {
        XCTAssertEqual(MessageContent.voice(duration: 4, fileId: "1", waveform: nil).playbackDuration, 4)
        XCTAssertEqual(
            MessageContent.videoNote(duration: 9, fileId: "1", thumbnailId: nil, minithumbnail: nil).playbackDuration, 9
        )
        XCTAssertNil(
            MessageContent.photo(caption: .empty, fileId: "1", width: 1, height: 1, minithumbnail: nil).playbackDuration
        )
    }

    // MARK: - Cache rule

    func testSelfDestructingFileIsNeverKeptInTheImageCache() async {
        let service = MockTelegramService()
        service.downloadedFiles["7"] = Data([1])
        let cache = ImageCache(service: service, thumbnailDecoder: Self.decoder)
        cache.excludeFromCache(fileIds: ["7"])

        let first = await cache.load(fileId: "7")
        let second = await cache.load(fileId: "7")

        XCTAssertNotNil(first, "The viewer still gets its image")
        XCTAssertNotNil(second)
        XCTAssertEqual(service.requestedDownloads, ["7", "7"], "Nothing was kept to answer the second load")
        XCTAssertEqual(cache.decodedImageBytes, 0)
    }

    func testOrdinaryFileIsKeptInTheImageCache() async {
        let service = MockTelegramService()
        service.downloadedFiles["7"] = Data([1])
        let cache = ImageCache(service: service, thumbnailDecoder: Self.decoder)

        _ = await cache.load(fileId: "7")
        _ = await cache.load(fileId: "7")

        XCTAssertEqual(service.requestedDownloads, ["7"])
        XCTAssertGreaterThan(cache.decodedImageBytes, 0)
    }

    func testExcludingACachedFileDropsWhatTheCacheHeld() async {
        let service = MockTelegramService()
        service.downloadedFiles["7"] = Data([1])
        let cache = ImageCache(service: service, thumbnailDecoder: Self.decoder)
        _ = await cache.load(fileId: "7")
        XCTAssertGreaterThan(cache.decodedImageBytes, 0)

        cache.excludeFromCache(fileIds: ["7"])

        XCTAssertEqual(cache.decodedImageBytes, 0)
        let cached = await cache.cachedData(fileId: "7")
        XCTAssertNil(cached)
    }

    func testClearingTheCacheForgetsExclusionsOfTheEndedSession() async {
        let service = MockTelegramService()
        service.downloadedFiles["7"] = Data([1])
        let cache = ImageCache(service: service, thumbnailDecoder: Self.decoder)
        cache.excludeFromCache(fileIds: ["7"])

        cache.clear()
        _ = await cache.load(fileId: "7")

        XCTAssertGreaterThan(cache.decodedImageBytes, 0, "File 7 of the next session is an ordinary file")
    }

    func testSelfDestructingPlaybackCopyIsDeletedWithTheExclusion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-destruct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("self-destruct-\(UUID().uuidString).mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let service = MockTelegramService()
        service.localFileURLs["9"] = source
        let cache = ImageCache(
            service: service,
            playbackFiles: SharedPlaybackFiles(directory: { directory })
        )
        let loaded = await cache.loadSharedPlaybackFile(fileId: "9")
        let copy = try XCTUnwrap(loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

        cache.excludeFromCache(fileIds: ["9"])

        try await waitUntil { !FileManager.default.fileExists(atPath: copy.path) }
    }

    // MARK: - Local expiry

    func testExpiringAMessageReplacesItsMediaWithNothingToOpen() {
        let store = Self.makeStore()
        store.reset(chatId: 5)
        var viewOnce = MessageInfo(
            id: 1, chatId: 5, senderName: "A", senderId: 2,
            content: .video(caption: .empty, fileId: "8", thumbnailId: nil, width: 1, height: 1, duration: 2, minithumbnail: nil),
            date: Date(timeIntervalSince1970: 0), isOutgoing: false, isRead: false
        )
        viewOnce.selfDestruct = .viewOnce
        let other = MessageInfo(
            id: 2, chatId: 5, senderName: "A", senderId: 2, content: .text("stays"),
            date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: false
        )
        store.handleIncomingMessage(viewOnce)
        store.handleIncomingMessage(other)

        store.expireSelfDestructingMedia(chatId: 5, messageId: 1)

        let messages = store.messages(for: 5)
        XCTAssertEqual(messages.first?.content, .expiredMedia(.video))
        XCTAssertFalse(messages.first?.isSelfDestructingMedia ?? true, "Nothing is left to open again")
        XCTAssertEqual(messages.last?.content, .text("stays"))
    }

    func testExpiringAnOrdinaryMessageChangesNothing() {
        let store = Self.makeStore()
        store.reset(chatId: 5)
        let photo = MessageInfo(
            id: 1, chatId: 5, senderName: "A", senderId: 2,
            content: .photo(caption: .empty, fileId: "8", width: 1, height: 1, minithumbnail: nil),
            date: Date(timeIntervalSince1970: 0), isOutgoing: false, isRead: false
        )
        store.handleIncomingMessage(photo)

        store.expireSelfDestructingMedia(chatId: 5, messageId: 1)

        XCTAssertEqual(store.messages(for: 5).first?.content, photo.content)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let photoContent: [String: Any] = [
        "@type": "messagePhoto",
        "is_secret": true,
        "photo": [
            "@type": "photo",
            "sizes": [[
                "@type": "photoSize", "type": "x", "width": 800, "height": 600,
                "photo": ["@type": "file", "id": 41] as [String: Any]
            ] as [String: Any]]
        ] as [String: Any]
    ]

    private static let voiceContent: [String: Any] = [
        "@type": "messageVoiceNote",
        "voice_note": [
            "@type": "voiceNote", "duration": 4,
            "voice": ["@type": "file", "id": 42] as [String: Any]
        ] as [String: Any]
    ]

    private static func message(content: [String: Any], selfDestructType: [String: Any]? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "@type": "message",
            "id": 100,
            "chat_id": 200,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 0] as [String: Any],
            "content": content
        ]
        dict["self_destruct_type"] = selfDestructType
        return dict
    }

    private static let decoder: ImageCache.ThumbnailDecoder = { _, _ in
        UIImage(data: RecordingFiles.imageData())
    }

    private static func makeStore() -> ChatMessageStore {
        let service = MockTelegramService()
        let repository = ChatRepository(
            service: service,
            draftStore: DraftStore(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        return ChatMessageStore(
            messageManager: MessageManager(service: service, messageQueue: MessageQueue()),
            chatRepository: repository
        )
    }
}
