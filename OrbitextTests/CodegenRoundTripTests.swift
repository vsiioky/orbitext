import XCTest
@testable import OrbitextWatch

/// Round-trip tests for the generated TDApi.* models and decoders.
///
/// Each test builds a TDLib-shaped `[String: Any]` dict the same way TDLib's
/// JSON deserializer would (snake_case keys, `@type` discriminator, numeric
/// fields as `Int`/`Double`, `int64` as either `Int` or `String`, bytes as
/// base64 strings) and asserts the decoder pulls out the expected fields,
/// nested objects, and enum cases.
///
/// Scope is the read-path subset described in
/// `Orbitext/Telegram/Generated/README.md`. These tests are the contract
/// the domain migration relies on; if you change a decoder, keep
/// them green.
final class CodegenRoundTripTests: XCTestCase {
    // MARK: - Primitives and coercion helpers

    func testInt32CoercesFromIntAndString() {
        XCTAssertEqual(TDApi.int32(42), 42)
        XCTAssertEqual(TDApi.int32(NSNumber(value: 7)), 7)
        XCTAssertEqual(TDApi.int32("13"), 13)
        XCTAssertEqual(TDApi.int32(nil), 0)
    }

    func testInt64CoercesFromStringPayload() {
        // TDLib serializes int53/int64 as JSON strings when the value would
        // lose precision in a JS number. Make sure both paths work.
        XCTAssertEqual(TDApi.int64("9223372036854775000"), 9223372036854775000)
        XCTAssertEqual(TDApi.int64(NSNumber(value: 5_000_000_000)), 5_000_000_000)
        XCTAssertEqual(TDApi.int64(123), 123)
    }

    func testBytesAcceptsBase64StringAndRawData() {
        let raw = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let b64 = raw.base64EncodedString()
        XCTAssertEqual(TDApi.bytes(b64), raw)
        XCTAssertEqual(TDApi.bytes(raw), raw)
        XCTAssertEqual(TDApi.bytes(nil), Data())
    }

    func testBoolCoercion() {
        XCTAssertTrue(TDApi.bool(true))
        XCTAssertTrue(TDApi.bool(NSNumber(value: true)))
        XCTAssertTrue(TDApi.bool("1"))
        XCTAssertFalse(TDApi.bool(nil))
        XCTAssertFalse(TDApi.bool("nope"))
    }

    // MARK: - FormattedText + TextEntity

    func testFormattedTextDecodesNestedEntities() {
        let dict: [String: Any] = [
            "@type": "formattedText",
            "text": "Hello bold world",
            "entities": [
                [
                    "@type": "textEntity",
                    "offset": 6,
                    "length": 4,
                    "type": ["@type": "textEntityTypeBold"],
                ],
            ],
        ]
        let ft = TDApi.decodeFormattedText(dict)
        XCTAssertEqual(ft.text, "Hello bold world")
        XCTAssertEqual(ft.entities.count, 1)
        XCTAssertEqual(ft.entities[0].offset, 6)
        XCTAssertEqual(ft.entities[0].length, 4)
        switch ft.entities[0].type {
        case .textEntityTypeBold:
            break
        default:
            XCTFail("expected bold entity, got \(String(describing: ft.entities[0].type))")
        }
    }

    func testFormattedTextHandlesMissingEntitiesAsEmpty() {
        let dict: [String: Any] = ["@type": "formattedText", "text": "no entities"]
        let ft = TDApi.decodeFormattedText(dict)
        XCTAssertEqual(ft.text, "no entities")
        XCTAssertTrue(ft.entities.isEmpty)
    }

    // MARK: - File / LocalFile / RemoteFile

    func testFileDecodesNestedLocalAndRemote() {
        let dict: [String: Any] = [
            "@type": "file",
            "id": 11,
            "size": 1024,
            "expected_size": 1024,
            "local": [
                "@type": "localFile",
                "path": "/tmp/x.jpg",
                "can_be_downloaded": true,
                "can_be_deleted": false,
                "is_downloading_active": false,
                "is_downloading_completed": true,
                "download_offset": 0,
                "downloaded_prefix_size": 1024,
                "downloaded_size": 1024,
            ],
            "remote": [
                "@type": "remoteFile",
                "id": "rem-id",
                "unique_id": "uniq",
                "is_uploading_active": false,
                "is_uploading_completed": true,
                "uploaded_size": 1024,
            ],
        ]
        let file = TDApi.decodeFile(dict)
        XCTAssertEqual(file.id, 11)
        XCTAssertEqual(file.size, 1024)
        XCTAssertEqual(file.local?.path, "/tmp/x.jpg")
        XCTAssertTrue(file.local?.isDownloadingCompleted ?? false)
        XCTAssertEqual(file.remote?.id, "rem-id")
        XCTAssertEqual(file.remote?.uniqueId, "uniq")
    }

    func testFileReturnsNilOptionalForMissingRemote() {
        let dict: [String: Any] = ["@type": "file", "id": 1, "size": 0, "expected_size": 0]
        let file = TDApi.decodeFile(dict)
        XCTAssertNil(file.local)
        XCTAssertNil(file.remote)
        XCTAssertEqual(file.id, 1)
    }

    // MARK: - MessageContent variants

    func testMessageContentTextVariant() {
        let dict: [String: Any] = [
            "@type": "messageText",
            "text": [
                "@type": "formattedText",
                "text": "hi",
                "entities": [Any](),
            ],
        ]
        let content = TDApi.decodeMessageContent(dict)
        switch content {
        case .messageText(let payload):
            XCTAssertEqual(payload.text?.text, "hi")
        default:
            XCTFail("expected messageText, got \(content)")
        }
    }

    func testMessageContentPhotoCarriesCaption() {
        let dict: [String: Any] = [
            "@type": "messagePhoto",
            "photo": [
                "@type": "photo",
                "has_stickers": false,
                "minithumbnail": NSNull(),
                "sizes": [Any](),
            ],
            "caption": [
                "@type": "formattedText",
                "text": "look",
                "entities": [Any](),
            ],
            "is_secret": false,
        ]
        let content = TDApi.decodeMessageContent(dict)
        switch content {
        case .messagePhoto(let payload):
            XCTAssertEqual(payload.caption?.text, "look")
            XCTAssertFalse(payload.isSecret)
        default:
            XCTFail("expected messagePhoto, got \(content)")
        }
    }

    func testMessageContentUnknownTagFallsBackToUnknown() {
        let dict: [String: Any] = ["@type": "messageWhateverNewVariant"]
        let content = TDApi.decodeMessageContent(dict)
        switch content {
        case .unknown(let tag):
            XCTAssertEqual(tag, "messageWhateverNewVariant")
        default:
            XCTFail("expected .unknown, got \(content)")
        }
    }

    func testMessageContentMissingTagReturnsUnknownEmpty() {
        let dict: [String: Any] = [:]
        let content = TDApi.decodeMessageContent(dict)
        switch content {
        case .unknown(let tag):
            XCTAssertEqual(tag, "")
        default:
            XCTFail("expected .unknown for empty dict")
        }
    }

    // MARK: - Update enum dispatch

    func testUpdateChatTitleDispatch() {
        let dict: [String: Any] = [
            "@type": "updateChatTitle",
            "chat_id": "5000000000",
            "title": "New title",
        ]
        let update = TDApi.decodeUpdate(dict)
        switch update {
        case .updateChatTitle(let payload):
            XCTAssertEqual(payload.chatId, 5_000_000_000)
            XCTAssertEqual(payload.title, "New title")
        default:
            XCTFail("expected updateChatTitle, got \(update)")
        }
    }

    func testUpdateMessageContentCarriesNestedContent() {
        let dict: [String: Any] = [
            "@type": "updateMessageContent",
            "chat_id": 100,
            "message_id": 42,
            "new_content": [
                "@type": "messageText",
                "text": [
                    "@type": "formattedText",
                    "text": "ping",
                    "entities": [Any](),
                ],
            ],
        ]
        let update = TDApi.decodeUpdate(dict)
        guard case .updateMessageContent(let payload) = update else {
            return XCTFail("expected updateMessageContent, got \(update)")
        }
        XCTAssertEqual(payload.chatId, 100)
        XCTAssertEqual(payload.messageId, 42)
        guard case .messageText(let text)? = payload.newContent else {
            return XCTFail("expected nested messageText")
        }
        XCTAssertEqual(text.text?.text, "ping")
    }

    func testMessageCarriesNestedContentAndSender() {
        let dict: [String: Any] = [
            "@type": "message",
            "id": 42,
            "chat_id": 100,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7],
            "is_outgoing": true,
            "date": 1_700_000_000,
            "content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "ping", "entities": [Any]()],
            ],
        ]
        let message = TDApi.decodeMessage(dict)
        XCTAssertEqual(message.id, 42)
        XCTAssertEqual(message.chatId, 100)
        XCTAssertTrue(message.isOutgoing)
        guard case .messageSenderUser(let sender)? = message.senderId else {
            return XCTFail("expected user sender")
        }
        XCTAssertEqual(sender.userId, 7)
        guard case .messageText(let text)? = message.content else {
            return XCTFail("expected nested messageText")
        }
        XCTAssertEqual(text.text?.text, "ping")
    }

    func testUpdateDeleteMessagesParsesInt64Vector() {
        let dict: [String: Any] = [
            "@type": "updateDeleteMessages",
            "chat_id": -100,
            "message_ids": ["1", "2", NSNumber(value: 3)],
            "is_permanent": true,
            "from_cache": false,
        ]
        let update = TDApi.decodeUpdate(dict)
        guard case .updateDeleteMessages(let payload) = update else {
            return XCTFail("expected updateDeleteMessages, got \(update)")
        }
        XCTAssertEqual(payload.chatId, -100)
        XCTAssertEqual(payload.messageIds, [1, 2, 3])
        XCTAssertTrue(payload.isPermanent)
        XCTAssertFalse(payload.fromCache)
    }

    func testUpdateConnectionStateNestedEnum() {
        let dict: [String: Any] = [
            "@type": "updateConnectionState",
            "state": ["@type": "connectionStateReady"],
        ]
        let update = TDApi.decodeUpdate(dict)
        guard case .updateConnectionState(let payload) = update else {
            return XCTFail("expected updateConnectionState, got \(update)")
        }
        guard case .connectionStateReady? = payload.state else {
            return XCTFail("expected connectionStateReady, got \(String(describing: payload.state))")
        }
    }

    func testOmittedUpdateTypeReachesUnknownCase() {
        // Updates the app does not decode are not in the generated enum
        // (scripts/codegen-roots.txt) and surface as .unknown with the tag.
        let update = TDApi.decodeUpdate(["@type": "updateNewChat"])
        guard case .unknown(let tag) = update else {
            return XCTFail("expected .unknown, got \(update)")
        }
        XCTAssertEqual(tag, "updateNewChat")
    }

    func testUpdateUnknownTagReachesUnknownCase() {
        let dict: [String: Any] = ["@type": "updateSomethingFromTheFuture"]
        let update = TDApi.decodeUpdate(dict)
        guard case .unknown(let tag) = update else {
            return XCTFail("expected .unknown, got \(update)")
        }
        XCTAssertEqual(tag, "updateSomethingFromTheFuture")
    }

    // MARK: - Nested objects and enums (chat position)

    func testChatPositionNestedListAndInt64OrderFromString() {
        let dict: [String: Any] = [
            "@type": "updateChatPosition",
            "chat_id": 9,
            "position": [
                "@type": "chatPosition",
                "list": ["@type": "chatListFolder", "chat_folder_id": 3],
                "order": "9223372036854775000",
                "is_pinned": true,
                "source": NSNull(),
            ],
        ]
        let update = TDApi.decodeUpdate(dict)
        guard case .updateChatPosition(let payload) = update else {
            return XCTFail("expected updateChatPosition, got \(update)")
        }
        XCTAssertEqual(payload.chatId, 9)
        XCTAssertEqual(payload.position?.order, 9_223_372_036_854_775_000)
        XCTAssertTrue(payload.position?.isPinned ?? false)
        XCTAssertNil(payload.position?.source)
        guard case .chatListFolder(let folder)? = payload.position?.list else {
            return XCTFail("expected folder list, got \(String(describing: payload.position?.list))")
        }
        XCTAssertEqual(folder.chatFolderId, 3)
    }

    // MARK: - ChatAction

    func testChatActionTypingDecodes() {
        guard case .chatActionTyping = TDApi.decodeChatAction(["@type": "chatActionTyping"]) else {
            return XCTFail("expected typing action")
        }
        XCTAssertEqual(ChatActionKind(tdApi: TDApi.decodeChatAction(["@type": "chatActionTyping"])), .typing)
    }

    func testChatActionCarriesProgress() {
        let action = TDApi.decodeChatAction(["@type": "chatActionUploadingPhoto", "progress": 40])
        guard case .chatActionUploadingPhoto(let payload) = action else {
            return XCTFail("expected uploading photo, got \(action)")
        }
        XCTAssertEqual(payload.progress, 40)
    }

    // MARK: - Defaults for missing primitives

    func testMissingPrimitivesDefaultToZeroAndEmpty() {
        // updateChatReadInbox has chat_id, last_read_inbox_message_id,
        // unread_count. Omit unread_count entirely - decoder should default
        // to 0 rather than crash.
        let dict: [String: Any] = [
            "@type": "updateChatReadInbox",
            "chat_id": 1,
            "last_read_inbox_message_id": 99,
        ]
        let update = TDApi.decodeUpdate(dict)
        guard case .updateChatReadInbox(let payload) = update else {
            return XCTFail("expected updateChatReadInbox, got \(update)")
        }
        XCTAssertEqual(payload.chatId, 1)
        XCTAssertEqual(payload.lastReadInboxMessageId, 99)
        XCTAssertEqual(payload.unreadCount, 0)
    }

    // MARK: - Vector of objects (TextEntities + Photo sizes)

    func testTextEntitiesVectorOfObjects() {
        let dict: [String: Any] = [
            "@type": "formattedText",
            "text": "@a link",
            "entities": [
                [
                    "@type": "textEntity",
                    "offset": 0,
                    "length": 2,
                    "type": ["@type": "textEntityTypeMention"],
                ],
                [
                    "@type": "textEntity",
                    "offset": 5,
                    "length": 3,
                    "type": ["@type": "textEntityTypeUrl"],
                ],
            ],
        ]
        let text = TDApi.decodeFormattedText(dict)
        XCTAssertEqual(text.entities.count, 2)
        XCTAssertEqual(text.entities[0].length, 2)
        XCTAssertEqual(text.entities[1].offset, 5)
    }

    func testPhotoSizeVectorOfPrimitives() {
        let dict: [String: Any] = [
            "@type": "photoSize",
            "type": "x",
            "photo": [
                "@type": "file",
                "id": 1, "size": 0, "expected_size": 0,
            ],
            "width": 320,
            "height": 240,
            "progressive_sizes": [10, 20, 30],
        ]
        let size = TDApi.decodePhotoSize(dict)
        XCTAssertEqual(size.type, "x")
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 240)
        XCTAssertEqual(size.progressiveSizes, [10, 20, 30])
        XCTAssertEqual(size.photo?.id, 1)
    }

    // MARK: - Minithumbnail bytes round-trip

    func testMinithumbnailRoundTripsBase64Bytes() {
        let raw = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let dict: [String: Any] = [
            "@type": "minithumbnail",
            "width": 32,
            "height": 32,
            "data": raw.base64EncodedString(),
        ]
        let thumb = TDApi.decodeMinithumbnail(dict)
        XCTAssertEqual(thumb.width, 32)
        XCTAssertEqual(thumb.data, raw)
    }
}
