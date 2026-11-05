import XCTest
@testable import OrbitextWatch

/// The typed TDApi -> domain mapping layer: FormattedString, MessageContent
/// and MessageInfo built from TDLib-shaped `[String: Any]` dicts through the
/// generated decoders (and through `parseMessageInfo`, which decodes once
/// and maps).
final class MessageMappingTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - FormattedString round-trip

    func testFormattedStringRoundTripsBoldAndTextUrl() {
        let dict: [String: Any] = [
            "@type": "formattedText",
            "text": "see Apple here",
            "entities": [
                ["@type": "textEntity", "offset": 4, "length": 5,
                 "type": ["@type": "textEntityTypeBold"] as [String: Any]] as [String: Any],
                ["@type": "textEntity", "offset": 10, "length": 4,
                 "type": ["@type": "textEntityTypeTextUrl", "url": "https://apple.com"] as [String: Any]] as [String: Any]
            ]
        ]
        let decoded = TDApi.decodeFormattedText(dict)
        let viaTyped = FormattedString(tdApi: decoded)
        XCTAssertEqual(viaTyped.entities.count, 2)
        if case .textUrl(_, _, let href) = viaTyped.entities[1] {
            XCTAssertEqual(href, "https://apple.com")
        } else {
            XCTFail("expected textUrl")
        }
    }

    func testFormattedStringMentionNamePreservesUserId() {
        let dict: [String: Any] = [
            "@type": "formattedText",
            "text": "Hi Alice",
            "entities": [
                ["@type": "textEntity", "offset": 3, "length": 5,
                 "type": ["@type": "textEntityTypeMentionName", "user_id": 4242] as [String: Any]] as [String: Any]
            ]
        ]
        let decoded = TDApi.decodeFormattedText(dict)
        let viaTyped = FormattedString(tdApi: decoded)
        guard case .mentionName(_, _, let userId) = viaTyped.entities.first else {
            return XCTFail("expected mentionName")
        }
        XCTAssertEqual(userId, 4242)
    }

    // MARK: - Spoiler, quote and custom emoji entities

    func testMessageTextKeepsSpoilerAndQuoteEntities() {
        let content: [String: Any] = [
            "@type": "messageText",
            "text": [
                "@type": "formattedText",
                "text": "secret quote more",
                "entities": [
                    textEntity(offset: 0, length: 6, type: "textEntityTypeSpoiler"),
                    textEntity(offset: 7, length: 5, type: "textEntityTypeBlockQuote"),
                    textEntity(offset: 13, length: 4, type: "textEntityTypeExpandableBlockQuote")
                ]
            ] as [String: Any]
        ]

        guard case .text(let formatted) = MessageContent.parsed(content) else {
            return XCTFail("expected text")
        }

        XCTAssertTrue(formatted.hasSpoiler, "Spoiler text is shown uncovered and cannot be tapped to reveal")
        XCTAssertEqual(formatted.entities, [
            .spoiler(offset: 0, length: 6),
            .blockQuote(offset: 7, length: 5),
            .blockQuote(offset: 13, length: 4)
        ])
    }

    func testCaptionEntitiesKeepSpoilerAndQuote() {
        let caption: [String: Any] = [
            "@type": "formattedText",
            "text": "photo with spoiler",
            "entities": [
                textEntity(offset: 11, length: 7, type: "textEntityTypeSpoiler"),
                textEntity(offset: 0, length: 5, type: "textEntityTypeBlockQuote")
            ]
        ]

        let viaTyped = FormattedString(tdApi: TDApi.decodeFormattedText(caption))

        XCTAssertEqual(viaTyped.entities, [.spoiler(offset: 11, length: 7), .blockQuote(offset: 0, length: 5)])
        XCTAssertTrue(viaTyped.hasSpoiler)
    }

    func testEntitiesKeepCustomEmojiAndDropWhatTheDomainCannotShow() {
        let text: [String: Any] = [
            "@type": "formattedText",
            "text": "emoji 12:00 4111 end",
            "entities": [
                ["@type": "textEntity", "offset": 0, "length": 5,
                 "type": ["@type": "textEntityTypeCustomEmoji", "custom_emoji_id": "987654321"] as [String: Any]] as [String: Any],
                ["@type": "textEntity", "offset": 6, "length": 5,
                 "type": ["@type": "textEntityTypeDateTime", "unix_time": 1_700_000_000] as [String: Any]] as [String: Any],
                textEntity(offset: 12, length: 4, type: "textEntityTypeBankCardNumber")
            ]
        ]

        let viaTyped = FormattedString(tdApi: TDApi.decodeFormattedText(text))

        XCTAssertEqual(viaTyped.entities, [.customEmoji(offset: 0, length: 5, emojiId: 987_654_321)])
    }

    private func textEntity(offset: Int, length: Int, type: String) -> [String: Any] {
        ["@type": "textEntity", "offset": offset, "length": length, "type": ["@type": type] as [String: Any]]
    }

    // MARK: - MessageContent from TDLib JSON

    func testTextContentMapsToItsFormattedText() {
        let content: [String: Any] = [
            "@type": "messageText",
            "text": ["@type": "formattedText", "text": "Hello"] as [String: Any]
        ]
        XCTAssertEqual(MessageContent.parsed(content), .text(FormattedString(text: "Hello")))
    }

    func testTypedPhotoIncludesMinithumbnailAndBestSize() {
        let raw = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02])
        let b64 = raw.base64EncodedString()
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": "snap"] as [String: Any],
            "photo": [
                "minithumbnail": ["data": b64] as [String: Any],
                "sizes": [
                    ["photo": ["id": 11] as [String: Any], "width": 90, "height": 90] as [String: Any],
                    ["photo": ["id": 42] as [String: Any], "width": 320, "height": 240] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .photo(_, let fileId, let w, let h, let mini, _) = parsed {
            XCTAssertEqual(fileId, "42")
            XCTAssertEqual(w, 320)
            XCTAssertEqual(h, 240)
            XCTAssertEqual(mini, raw)
        } else {
            XCTFail("expected photo")
        }
    }

    // MARK: - Photo preview size

    /// A chat draws a photo 120pt wide (240 px). The full-size file is for the
    /// viewer; the message shows the smallest size that still fills the tile.
    func testPhotoPreviewIsTheSmallestSizeThatFillsTheThumbnail() {
        let parsed = MessageContent.parsed(photoContent(sizes: [
            (1, 90, 90), (2, 320, 320), (3, 800, 800), (4, 1280, 1280)
        ]))

        guard case .photo(_, let fileId, let w, let h, _, let previewFileId) = parsed else { return XCTFail("expected photo") }
        XCTAssertEqual(fileId, "4", "The viewer opens the largest size")
        XCTAssertEqual(previewFileId, "2", "The tile needs 240 px of width, and 320 is the first size that has it")
        XCTAssertEqual([w, h], [1280, 1280])
    }

    /// The tile is as wide as it is for a landscape photo, so a tall photo
    /// needs a size that is wide enough, not only long enough.
    func testPhotoPreviewOfATallPhotoLooksAtTheWidth() {
        let parsed = MessageContent.parsed(photoContent(sizes: [
            (1, 56, 100), (2, 180, 320), (3, 450, 800), (4, 720, 1280)
        ]))

        guard case .photo(_, _, _, _, _, let previewFileId) = parsed else { return XCTFail("expected photo") }
        XCTAssertEqual(previewFileId, "3", "180 px wide would be stretched to 240")
    }

    func testPhotoWithNoSizeAboveThePreviewWidthHasNoSeparatePreview() {
        let small = MessageContent.parsed(photoContent(sizes: [(1, 90, 90), (2, 200, 150)]))
        let single = MessageContent.parsed(photoContent(sizes: [(7, 1280, 960)]))
        let barelyBigEnough = MessageContent.parsed(photoContent(sizes: [(1, 90, 90), (2, 320, 240)]))

        for (name, parsed) in [("small", small), ("single", single), ("barely", barelyBigEnough)] {
            guard case .photo(_, _, _, _, _, let previewFileId) = parsed else { return XCTFail("expected photo") }
            XCTAssertNil(previewFileId, "\(name): the full-size file is the only one worth drawing")
        }
    }

    func testPhotoPreviewSkipsSizesWithoutAFile() {
        let parsed = MessageContent.parsed(photoContent(sizes: [(0, 320, 320), (2, 800, 800), (3, 1280, 1280)]))

        guard case .photo(_, let fileId, _, _, _, let previewFileId) = parsed else { return XCTFail("expected photo") }
        XCTAssertEqual(fileId, "3")
        XCTAssertEqual(previewFileId, "2")
    }

    /// The cold-start files hold the last message of each chat. One written
    /// before the preview field existed must still load, or every chat would
    /// come back empty after the update.
    func testPhotoSavedBeforeThePreviewFieldStillDecodes() throws {
        let saved = MessageContent.photo(
            caption: FormattedString(text: "old"), fileId: "42", width: 320, height: 240, minithumbnail: nil, previewFileId: "7"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        let payload = try XCTUnwrap(json["photo"] as? [String: Any])
        XCTAssertEqual(payload["previewFileId"] as? String, "7", "The test must be removing a key that is written")

        var old = payload
        old.removeValue(forKey: "previewFileId")
        let decoded = try JSONDecoder().decode(
            MessageContent.self, from: JSONSerialization.data(withJSONObject: ["photo": old])
        )

        XCTAssertEqual(decoded, .photo(caption: FormattedString(text: "old"), fileId: "42", width: 320, height: 240, minithumbnail: nil))
        let roundTrip = try JSONDecoder().decode(MessageContent.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip, saved)
    }

    private func photoContent(sizes: [(id: Int, width: Int, height: Int)]) -> [String: Any] {
        [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": [
                "sizes": sizes.map { size in
                    ["photo": ["id": size.id] as [String: Any], "width": size.width, "height": size.height] as [String: Any]
                }
            ] as [String: Any]
        ]
    }

    func testTypedVideoCarriesThumbnailAndMinithumbnail() {
        let raw = Data([0x10, 0x20, 0x30])
        let b64 = raw.base64EncodedString()
        let content: [String: Any] = [
            "@type": "messageVideo",
            "caption": ["text": "clip"] as [String: Any],
            "video": [
                "duration": 11,
                "width": 320,
                "height": 180,
                "minithumbnail": ["data": b64] as [String: Any],
                "video": ["id": 345] as [String: Any],
                "thumbnail": ["file": ["id": 678] as [String: Any]] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .video(_, let fileId, let thumb, let w, let h, let d, let mini) = parsed {
            XCTAssertEqual(fileId, "345")
            XCTAssertEqual(thumb, "678")
            XCTAssertEqual(w, 320)
            XCTAssertEqual(h, 180)
            XCTAssertEqual(d, 11)
            XCTAssertEqual(mini, raw)
        } else {
            XCTFail("expected video")
        }
    }

    func testTypedVoiceDecodesWaveform() {
        // 5-bit packed waveform: all 0xFF -> peaks = 31 each.
        let waveform = Data(repeating: 0xFF, count: 8) // 12 peaks
        let content: [String: Any] = [
            "@type": "messageVoiceNote",
            "voice_note": [
                "duration": 15,
                "voice": ["id": 99] as [String: Any],
                "waveform": waveform.base64EncodedString()
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .voice(let duration, let fileId, let peaks) = parsed {
            XCTAssertEqual(duration, 15)
            XCTAssertEqual(fileId, "99")
            XCTAssertEqual(peaks?.count, 12)
            XCTAssertTrue(peaks?.allSatisfy { $0 == 31 } ?? false)
        } else {
            XCTFail("expected voice")
        }
    }

    func testTypedVoiceWithoutWaveformIsNil() {
        let content: [String: Any] = [
            "@type": "messageVoiceNote",
            "voice_note": [
                "duration": 5,
                "voice": ["id": 7] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .voice(_, _, let peaks) = parsed {
            XCTAssertNil(peaks)
        } else {
            XCTFail("expected voice")
        }
    }

    func testTypedLocationWithoutLivePeriod() {
        let content: [String: Any] = [
            "@type": "messageLocation",
            "location": ["latitude": 41.299496, "longitude": 69.240073] as [String: Any],
            "live_period": 0
        ]
        let parsed = MessageContent.parsed(content)
        if case .location(_, _, let live) = parsed {
            XCTAssertNil(live)
        } else {
            XCTFail("expected location")
        }
    }

    func testTypedLiveLocation() {
        let content: [String: Any] = [
            "@type": "messageLocation",
            "location": ["latitude": 41.0, "longitude": 69.0] as [String: Any],
            "live_period": 900
        ]
        let parsed = MessageContent.parsed(content)
        if case .location(_, _, let live) = parsed {
            XCTAssertEqual(live, 900)
        } else {
            XCTFail("expected live location")
        }
    }

    func testTypedCallMissed() {
        let content: [String: Any] = [
            "@type": "messageCall",
            "duration": 120,
            "is_video": false,
            "discard_reason": ["@type": "callDiscardReasonMissed"] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .call(let d, let v, let reason) = parsed {
            XCTAssertEqual(d, 120)
            XCTAssertFalse(v)
            XCTAssertEqual(reason, "callDiscardReasonMissed")
        } else {
            XCTFail("expected call")
        }
    }

    func testTypedPinnedAndChatCreatedAndMemberJoinedAndLeft() {
        XCTAssertEqual(
            MessageContent(tdApi: TDApi.decodeMessageContent(["@type": "messagePinMessage"])),
            .pinnedMessage
        )
        XCTAssertEqual(
            MessageContent(tdApi: TDApi.decodeMessageContent(["@type": "messageBasicGroupChatCreate"])),
            .chatCreated
        )
        XCTAssertEqual(
            MessageContent(tdApi: TDApi.decodeMessageContent(["@type": "messageChatJoinByLink"])),
            .memberJoined
        )
        XCTAssertEqual(
            MessageContent(tdApi: TDApi.decodeMessageContent(["@type": "messageChatDeleteMember"])),
            .memberLeft
        )
    }

    func testTypedPollShowsTheQuestionText() {
        let content: [String: Any] = [
            "@type": "messagePoll",
            "poll": [
                "@type": "poll",
                "question": ["@type": "formattedText", "text": "Favorite color?", "entities": [Any]()] as [String: Any]
            ] as [String: Any]
        ]
        XCTAssertEqual(MessageContent(tdApi: TDApi.decodeMessageContent(content)), .poll(question: "Favorite color?"))
        XCTAssertEqual(MessageContent.parsed(content), .poll(question: "Favorite color?"))
    }

    // MARK: - Full MessageInfo via typed path

    func testTypedMessageInfoTextWithSenderResolution() {
        service.userCache.set(123, .sample(id: 123, firstName: "John", lastName: "Doe"))
        let dict: [String: Any] = [
            "id": 555,
            "chat_id": 777,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "media_album_id": "9876543210",
            "sender_id": ["@type": "messageSenderUser", "user_id": 123] as [String: Any],
            "content": [
                "@type": "messageText",
                "text": ["text": "hi"] as [String: Any]
            ] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, 555)
        XCTAssertEqual(info?.chatId, 777)
        XCTAssertEqual(info?.senderId, 123)
        XCTAssertEqual(info?.senderName, "John Doe")
        XCTAssertEqual(info?.mediaAlbumId, 9876543210)
        XCTAssertFalse(info?.isOutgoing ?? true)
        XCTAssertTrue(info?.senderResolved ?? false)
    }

    func testTypedMessageInfoPropagatesReactions() {
        let dict: [String: Any] = [
            "id": 1,
            "chat_id": 2,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "yo"] as [String: Any]] as [String: Any],
            "interaction_info": [
                "reactions": [
                    "@type": "messageReactions",
                    "reactions": [
                        [
                            "type": ["@type": "reactionTypeEmoji", "emoji": "🔥"] as [String: Any],
                            "total_count": 2,
                            "is_chosen": false
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertEqual(info?.reactions.count, 1)
        XCTAssertEqual(info?.reactions.first?.emoji, "🔥")
        XCTAssertEqual(info?.reactions.first?.count, 2)
    }

    func testTypedMessageInfoForwardedChannelOrigin() {
        service.chatCache.set(
            -2002,
            ChatInfo(id: -2002, title: "Tech Channel", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 0)
        )
        let dict: [String: Any] = [
            "id": 9,
            "chat_id": 99,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "fwd"] as [String: Any]] as [String: Any],
            "forward_info": [
                "origin": [
                    "@type": "messageOriginChannel",
                    "chat_id": -2002,
                    "author_signature": "Editor"
                ] as [String: Any]
            ] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertTrue(info?.forwardedOrigin?.isChannel ?? false)
        XCTAssertEqual(info?.forwardedOrigin?.displayName, "Tech Channel (Editor)")
    }

    func testTypedMessageInfoReplyWithQuotePreviewAndOrigin() {
        service.userCache.set(456, .sample(id: 456, firstName: "Reply", lastName: "Author"))
        let dict: [String: Any] = [
            "id": 10,
            "chat_id": 11,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "re"] as [String: Any]] as [String: Any],
            "reply_to": [
                "@type": "messageReplyToMessage",
                "message_id": 42,
                "quote": ["text": ["text": "original quoted line"] as [String: Any]] as [String: Any],
                "origin": [
                    "@type": "messageOriginUser",
                    "sender_user_id": 456
                ] as [String: Any]
            ] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertEqual(info?.replyToMessageId, 42)
        XCTAssertEqual(info?.replyToSenderName, "Reply Author")
        XCTAssertEqual(info?.replyToSenderUserId, 456)
        XCTAssertEqual(info?.replyToPreview?.text, "original quoted line")
        XCTAssertTrue(info?.replyToSenderResolved ?? false)
    }

    func testTypedMessageInfoReplyUserOriginStoresUnresolvedSenderId() {
        let dict: [String: Any] = [
            "id": 10,
            "chat_id": 11,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "re"] as [String: Any]] as [String: Any],
            "reply_to": [
                "@type": "messageReplyToMessage",
                "message_id": 42,
                "origin": [
                    "@type": "messageOriginUser",
                    "sender_user_id": 456
                ] as [String: Any]
            ] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertEqual(info?.replyToMessageId, 42)
        XCTAssertNil(info?.replyToSenderName)
        XCTAssertEqual(info?.replyToSenderUserId, 456)
        XCTAssertFalse(info?.replyToSenderResolved ?? true)
    }

    func testTypedMessageInfoFlagsSendingState() {
        let dict: [String: Any] = [
            "id": 22,
            "chat_id": 33,
            "is_outgoing": true,
            "date": 1_700_000_000,
            "sending_state": ["@type": "messageSendingStatePending"] as [String: Any],
            "sender_id": ["@type": "messageSenderUser", "user_id": 999] as [String: Any],
            "content": ["@type": "messageText", "text": ["text": "queued"] as [String: Any]] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertTrue(info?.isSending ?? false)
        XCTAssertTrue(info?.isOutgoing ?? false)
    }

    func testTypedMessageInfoServiceMemberJoinedFromJoinByRequest() {
        let dict: [String: Any] = [
            "id": 33,
            "chat_id": 44,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": ["@type": "messageSenderUser", "user_id": 5] as [String: Any],
            "content": ["@type": "messageChatJoinByRequest"] as [String: Any]
        ]
        let info = service.parseMessageInfo(dict)
        XCTAssertEqual(info?.content, .memberJoined)
    }
}
