import XCTest
@testable import OrbitextWatch

final class AttachmentServiceTests: XCTestCase {
    private let sticker = StickerOption(fileId: "42", emoji: "👍", thumbnailFileId: "43", width: 512, height: 256)

    func testStickerRequestReusesExistingFileAndSelectedChat() throws {
        let request = try TDLibAttachmentRequests.sticker(chatId: -100123, sticker: sticker)
        // Check the serialized boundary, not just Swift's heterogeneous dictionary.
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(json["input_message_content"] as? [String: Any])
        let file = try XCTUnwrap(content["sticker"] as? [String: Any])

        XCTAssertEqual(json["@type"] as? String, "sendMessage")
        XCTAssertEqual(json["chat_id"] as? Int64, -100123)
        XCTAssertEqual(content["@type"] as? String, "inputMessageSticker")
        XCTAssertEqual(file["@type"] as? String, "inputFileId")
        XCTAssertEqual(file["id"] as? Int, 42)
        XCTAssertEqual(content["width"] as? Int, 512)
        XCTAssertEqual(content["height"] as? Int, 256)
        XCTAssertEqual(content["emoji"] as? String, "👍")
        XCTAssertNil(content["thumbnail"], "Existing stickers must not re-upload picker thumbnails")
        XCTAssertNil(file["path"])
    }

    func testLocationRequestIsAlwaysOneTimeAndIncludesAccuracy() throws {
        let location = SharedLocation(latitude: 10.25, longitude: -20.5, horizontalAccuracy: 15)
        let request = try TDLibAttachmentRequests.location(chatId: 123, location: location)
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(json["input_message_content"] as? [String: Any])
        let coordinates = try XCTUnwrap(content["location"] as? [String: Any])

        XCTAssertEqual(json["chat_id"] as? Int, 123)
        XCTAssertEqual(content["@type"] as? String, "inputMessageLocation")
        XCTAssertEqual(coordinates["@type"] as? String, "location")
        XCTAssertEqual(coordinates["latitude"] as? Double, 10.25)
        XCTAssertEqual(coordinates["longitude"] as? Double, -20.5)
        XCTAssertEqual(coordinates["horizontal_accuracy"] as? Double, 15)
        XCTAssertEqual(content["live_period"] as? Int, 0)
        XCTAssertEqual(content["heading"] as? Int, 0)
        XCTAssertEqual(content["proximity_alert_radius"] as? Int, 0)
    }

    func testInvalidCoordinatesAndAccuracyCannotBecomePayloads() {
        let invalid: [SharedLocation] = [
            .init(latitude: .nan, longitude: 0, horizontalAccuracy: 0),
            .init(latitude: .infinity, longitude: 0, horizontalAccuracy: 0),
            .init(latitude: 90.01, longitude: 0, horizontalAccuracy: 0),
            .init(latitude: -90.01, longitude: 0, horizontalAccuracy: 0),
            .init(latitude: 0, longitude: .nan, horizontalAccuracy: 0),
            .init(latitude: 0, longitude: -.infinity, horizontalAccuracy: 0),
            .init(latitude: 0, longitude: 180.01, horizontalAccuracy: 0),
            .init(latitude: 0, longitude: -180.01, horizontalAccuracy: 0),
            .init(latitude: 0, longitude: 0, horizontalAccuracy: -1),
            .init(latitude: 0, longitude: 0, horizontalAccuracy: .nan),
            .init(latitude: 0, longitude: 0, horizontalAccuracy: .infinity)
        ]
        for location in invalid {
            XCTAssertFalse(location.isValid)
            XCTAssertThrowsError(try TDLibAttachmentRequests.location(chatId: 1, location: location)) { error in
                XCTAssertEqual(error as? ChatAttachmentError, .invalidLocation)
            }
        }
        XCTAssertNoThrow(try TDLibAttachmentRequests.location(
            chatId: 1, location: .init(latitude: -90, longitude: 180, horizontalAccuracy: 0)
        ))
    }

    func testInvalidStickerIdsCannotBecomePayloads() {
        for fileId in ["", "0", "-1", "not-a-file", "2147483648"] {
            let invalid = StickerOption(fileId: fileId, emoji: "", thumbnailFileId: nil, width: 512, height: 512)
            XCTAssertThrowsError(try TDLibAttachmentRequests.sticker(chatId: 1, sticker: invalid)) { error in
                XCTAssertEqual(error as? ChatAttachmentError, .invalidSticker)
            }
        }
    }

    func testParsesActualStickerFileNotStickerSetIdentifier() throws {
        var item = rawSticker(id: 42)
        item["id"] = 999
        item["set_id"] = "1234567890123456"
        item["thumbnail"] = ["file": ["id": 43]]
        let options = try TDLibAttachmentRequests.parseStickers(["@type": "stickers", "stickers": [item]])

        XCTAssertEqual(options, [sticker])
        XCTAssertEqual(options.first?.id, "42")
    }

    func testParserSkipsInvalidItemsAndInvalidThumbnail() throws {
        var withoutThumbnail = rawSticker(id: 42)
        withoutThumbnail["thumbnail"] = ["file": ["id": 0]]
        let malformed: [String: Any] = ["sticker": ["id": -1], "width": 512, "height": 512]
        let options = try TDLibAttachmentRequests.parseStickers([
            "@type": "stickers", "stickers": [malformed, withoutThumbnail]
        ])
        XCTAssertEqual(options.map(\.id), ["42"])
        XCTAssertNil(options.first?.thumbnailFileId)
    }

    func testMalformedResponseDoesNotMasqueradeAsEmptyLibrary() {
        for response: [String: Any] in [
            ["@type": "ok"],
            ["@type": "stickers"],
            ["@type": "stickers", "stickers": [["sticker": ["id": 0]]]]
        ] {
            XCTAssertThrowsError(try TDLibAttachmentRequests.parseStickers(response))
        }
        XCTAssertNoThrow(try TDLibAttachmentRequests.parseStickers(["@type": "stickers", "stickers": []]))
    }

    func testFavoritesAndRecentAreDeduplicatedAndRecentExcludesMasks() async throws {
        var requests: [[String: Any]] = []
        let options = try await TDLibAttachmentRequests.loadStickers { request in
            requests.append(request)
            return self.response(ids: requests.count == 1 ? [42, 43] : [43, 44])
        }

        XCTAssertEqual(options.map(\.id), ["42", "43", "44"])
        XCTAssertEqual(requests.map { $0["@type"] as? String }, ["getFavoriteStickers", "getRecentStickers"])
        XCTAssertEqual(requests.last?["is_attached"] as? Bool, false)
    }

    func testLibraryIsBoundedWithoutAdditionalRequestWhenFavoritesFillIt() async throws {
        var calls = 0
        let options = try await TDLibAttachmentRequests.loadStickers { _ in
            calls += 1
            return self.response(ids: Array(1...80))
        }
        XCTAssertEqual(options.count, 40)
        XCTAssertEqual(options.last?.id, "40")
        XCTAssertEqual(calls, 1)
    }

    func testUsefulPartialLibrarySurvivesOneSourceFailure() async throws {
        for failedSource in ["getFavoriteStickers", "getRecentStickers"] {
            let options = try await TDLibAttachmentRequests.loadStickers { request in
                if request["@type"] as? String == failedSource { throw TDError.timeout }
                return self.response(ids: [42])
            }
            XCTAssertEqual(options.map(\.id), ["42"])
        }
    }

    func testEmptyOtherSourceDoesNotHideLoadFailure() async {
        do {
            _ = try await TDLibAttachmentRequests.loadStickers { request in
                if request["@type"] as? String == "getFavoriteStickers" { throw TDError.timeout }
                return self.response(ids: [])
            }
            XCTFail("Expected failed load, not an empty account")
        } catch let error as TDError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationDoesNotContinueToOtherStickerSource() async {
        var calls = 0
        do {
            _ = try await TDLibAttachmentRequests.loadStickers { _ in
                calls += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(calls, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private func response(ids: [Int]) -> [String: Any] {
        ["@type": "stickers", "stickers": ids.map { rawSticker(id: $0) }]
    }

    private func rawSticker(id: Int) -> [String: Any] {
        ["@type": "sticker", "sticker": ["id": id], "emoji": "👍", "width": 512, "height": 256]
    }
}

@MainActor
final class AttachmentMessageManagerTests: XCTestCase {
    private var service: MockTelegramService!
    private var manager: MessageManager!
    private var queue: MessageQueue!
    private var presenter: ErrorPresenter!
    private let sticker = StickerOption(fileId: "42", emoji: "👍", thumbnailFileId: nil, width: 512, height: 256)

    override func setUp() async throws {
        service = MockTelegramService()
        // Keep tests independent from any persisted outgoing text queue.
        queue = MessageQueue(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("attachment-\(UUID()).json"))
        manager = MessageManager(service: service, messageQueue: queue)
        presenter = ErrorPresenter()
        manager.errorPresenter = presenter
    }

    func testLoadingStickersNeverSendsAnything() async throws {
        service.recentStickers = [sticker]
        let options = try await manager.loadRecentStickers()
        XCTAssertEqual(options, [sticker])
        XCTAssertTrue(service.sentStickers.isEmpty)
        XCTAssertTrue(service.sentLocations.isEmpty)
    }

    func testLoadErrorIsPropagatedForPickerRetry() async {
        service.getRecentStickersError = TDError.timeout
        do {
            _ = try await manager.loadRecentStickers()
            XCTFail("Expected load error")
        } catch let error as TDError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(presenter.error, "Picker owns its loading error presentation")
    }

    func testExplicitStickerSendTargetsChatAndEmitsRenderableMessage() async {
        let sent = await manager.sendSticker(chatId: 123, sticker: sticker)
        XCTAssertTrue(sent)
        XCTAssertEqual(service.sentStickers.first?.chatId, 123)
        XCTAssertEqual(service.sentStickers.first?.sticker, sticker)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        let emitted = expectation(description: "Attachment emits a new message")
        let stream = service.events
        let eventTask = Task {
            var events = stream.makeAsyncIterator()
            if case .newMessage(let message) = await events.next() {
                XCTAssertEqual(message.chatId, 123)
                XCTAssertEqual(message.content, .sticker(emoji: "👍", fileId: "42", thumbnailFileId: nil))
                emitted.fulfill()
            }
        }
        await fulfillment(of: [emitted], timeout: 1)
        eventTask.cancel()
    }

    func testExplicitLocationSendProducesStaticLocation() async {
        let location = SharedLocation(latitude: 10, longitude: 20, horizontalAccuracy: 15)
        let sent = await manager.sendLocation(chatId: 456, location: location)
        XCTAssertTrue(sent)
        XCTAssertEqual(service.sentLocations.first?.chatId, 456)
        XCTAssertEqual(service.sentLocations.first?.location, location)
        XCTAssertEqual(service.messagesByChatId[456]?.last?.content, .location(latitude: 10, longitude: 20, livePeriod: nil))
    }

    func testLocationAndStickerSendFailuresRemainFailuresWithoutTextQueue() async {
        service.sendStickerError = TDError.api(code: 400, message: "STICKER_INVALID")
        let stickerSent = await manager.sendSticker(chatId: 1, sticker: sticker)
        XCTAssertFalse(stickerSent)
        XCTAssertEqual(presenter.error, "STICKER_INVALID")

        service.sendLocationError = TDError.api(code: 400, message: "CHAT_WRITE_FORBIDDEN")
        let locationSent = await manager.sendLocation(chatId: 1, location: .init(latitude: 10, longitude: 20, horizontalAccuracy: 10))
        XCTAssertFalse(locationSent)
        XCTAssertEqual(presenter.error, "CHAT_WRITE_FORBIDDEN")
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(service.sentStickers.isEmpty)
        XCTAssertTrue(service.sentLocations.isEmpty)
    }

    func testInvalidLocationNeverReachesService() async {
        let sent = await manager.sendLocation(chatId: 1, location: .init(latitude: .nan, longitude: 20, horizontalAccuracy: 10))
        XCTAssertFalse(sent)
        XCTAssertTrue(service.sentLocations.isEmpty)
        XCTAssertNotNil(presenter.error)
    }

    func testCancelledAttachmentSendsDoNotShowErrors() async {
        service.sendStickerError = CancellationError()
        service.sendLocationError = CancellationError()
        let stickerSent = await manager.sendSticker(chatId: 1, sticker: sticker)
        let locationSent = await manager.sendLocation(chatId: 1, location: .init(latitude: 10, longitude: 20, horizontalAccuracy: 10))
        XCTAssertFalse(stickerSent)
        XCTAssertFalse(locationSent)
        XCTAssertNil(presenter.error)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }
}
