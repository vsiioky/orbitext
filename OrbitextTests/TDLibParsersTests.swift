import XCTest
@testable import OrbitextWatch

final class TDLibParsersTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        service = TDLibService()
    }

    // MARK: - parseChatInfo

    func testParseChatInfoBasic() {
        let dict: [String: Any] = [
            "id": 123,
            "title": "Test Chat",
            "unread_count": 5,
            "type": ["@type": "chatTypePrivate", "user_id": 456] as [String: Any]
        ]
        let chat = service.parseChatInfo(dict)
        XCTAssertEqual(chat.id, 123)
        XCTAssertEqual(chat.title, "Test Chat")
        XCTAssertEqual(chat.unreadCount, 5)
        XCTAssertFalse(chat.isGroup)
        XCTAssertFalse(chat.isChannel)
    }

    func testParseChatInfoSupergroup() {
        let dict: [String: Any] = [
            "id": 100,
            "title": "Group Chat",
            "unread_count": 0,
            "type": ["@type": "chatTypeSupergroup", "supergroup_id": 789, "is_channel": false] as [String: Any]
        ]
        let chat = service.parseChatInfo(dict)
        XCTAssertTrue(chat.isGroup)
        XCTAssertFalse(chat.isChannel)
    }

    func testParseChatInfoChannel() {
        let dict: [String: Any] = [
            "id": 200,
            "title": "News Channel",
            "unread_count": 0,
            "type": ["@type": "chatTypeSupergroup", "supergroup_id": 789, "is_channel": true] as [String: Any]
        ]
        let chat = service.parseChatInfo(dict)
        XCTAssertFalse(chat.isGroup)
        XCTAssertTrue(chat.isChannel)
    }

    func testParseChatInfoWithMute() {
        let dict: [String: Any] = [
            "id": 300,
            "title": "Muted",
            "unread_count": 0,
            "type": ["@type": "chatTypePrivate"] as [String: Any],
            "notification_settings": ["mute_for": 2147483647] as [String: Any]
        ]
        let chat = service.parseChatInfo(dict)
        XCTAssertTrue(chat.isMuted)
    }

    func testParseChatInfoReadsMainListPositionOrderAndPinnedState() {
        let dict: [String: Any] = [
            "id": 301,
            "title": "Pinned",
            "unread_count": 0,
            "type": ["@type": "chatTypePrivate", "user_id": 301] as [String: Any],
            "positions": [
                [
                    "@type": "chatPosition",
                    "list": ["@type": "chatListFolder", "chat_folder_id": 7] as [String: Any],
                    "order": 10,
                    "is_pinned": false
                ] as [String: Any],
                [
                    "@type": "chatPosition",
                    "list": ["@type": "chatListMain"] as [String: Any],
                    "order": 99,
                    "is_pinned": true
                ] as [String: Any]
            ]
        ]

        let chat = service.parseChatInfo(dict)

        XCTAssertEqual(chat.order, 99)
        XCTAssertTrue(chat.isPinned)
    }

    func testUpdateChatPositionIgnoresNonMainListPosition() {
        service.chatCache.set(
            302,
            ChatInfo(id: 302, title: "Stable", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 50)
        )

        service.handleUpdate([
            "@type": "updateChatPosition",
            "chat_id": 302,
            "position": [
                "@type": "chatPosition",
                "list": ["@type": "chatListFolder", "chat_folder_id": 7] as [String: Any],
                "order": 1,
                "is_pinned": true
            ] as [String: Any]
        ])

        let chat = service.chatCache.get(302)
        XCTAssertEqual(chat?.order, 50)
        XCTAssertFalse(chat?.isPinned ?? true)
    }

    // MARK: - MessageContent from TDLib JSON

    func testParseTextMessage() {
        let content: [String: Any] = [
            "@type": "messageText",
            "text": ["text": "Hello world"] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .text(let text) = parsed {
            XCTAssertEqual(text, "Hello world")
        } else {
            XCTFail("Expected .text, got \(parsed)")
        }
    }

    func testParsePhotoMessage() {
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": "Nice pic"] as [String: Any],
            "photo": [
                "sizes": [
                    ["photo": ["id": 42] as [String: Any], "width": 320, "height": 240] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .photo(let caption, let fileId, let w, let h, _, _) = parsed {
            XCTAssertEqual(caption, "Nice pic")
            XCTAssertEqual(fileId, "42")
            XCTAssertEqual(w, 320)
            XCTAssertEqual(h, 240)
        } else {
            XCTFail("Expected .photo, got \(parsed)")
        }
    }

    func testParseVoiceMessage() {
        let content: [String: Any] = [
            "@type": "messageVoiceNote",
            "voice_note": [
                "duration": 15,
                "voice": ["id": 99] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .voice(let duration, let fileId, let waveform) = parsed {
            XCTAssertEqual(duration, 15)
            XCTAssertEqual(fileId, "99")
            XCTAssertNil(waveform)
        } else {
            XCTFail("Expected .voice, got \(parsed)")
        }
    }

    func testParseAudioMessage() {
        let content: [String: Any] = [
            "@type": "messageAudio",
            "audio": [
                "title": "Track",
                "performer": "Artist",
                "duration": 42,
                "audio": ["id": 1234] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .audio(let title, let performer, let duration, let fileId) = parsed {
            XCTAssertEqual(title, "Track")
            XCTAssertEqual(performer, "Artist")
            XCTAssertEqual(duration, 42)
            XCTAssertEqual(fileId, "1234")
        } else {
            XCTFail("Expected .audio, got \(parsed)")
        }
    }

    func testParseVideoMessage() {
        let content: [String: Any] = [
            "@type": "messageVideo",
            "caption": ["text": "Clip"] as [String: Any],
            "video": [
                "duration": 11,
                "width": 320,
                "height": 180,
                "video": ["id": 345] as [String: Any],
                "thumbnail": ["file": ["id": 678] as [String: Any]] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .video(let caption, let fileId, let thumbnailId, let width, let height, let duration, _) = parsed {
            XCTAssertEqual(caption, "Clip")
            XCTAssertEqual(fileId, "345")
            XCTAssertEqual(thumbnailId, "678")
            XCTAssertEqual(width, 320)
            XCTAssertEqual(height, 180)
            XCTAssertEqual(duration, 11)
        } else {
            XCTFail("Expected .video, got \(parsed)")
        }
    }

    func testParseVideoNoteMessage() {
        let content: [String: Any] = [
            "@type": "messageVideoNote",
            "video_note": [
                "duration": 9,
                "video": ["id": 901] as [String: Any],
                "thumbnail": ["file": ["id": 902] as [String: Any]] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .videoNote(let duration, let fileId, let thumbnailId, _) = parsed {
            XCTAssertEqual(duration, 9)
            XCTAssertEqual(fileId, "901")
            XCTAssertEqual(thumbnailId, "902")
        } else {
            XCTFail("Expected .videoNote, got \(parsed)")
        }
    }

    func testParseMessageReactions() {
        let message: [String: Any] = [
            "id": 555,
            "chat_id": 777,
            "is_outgoing": false,
            "date": 1_700_000_000,
            "sender_id": [
                "@type": "messageSenderUser",
                "user_id": 123
            ] as [String: Any],
            "content": [
                "@type": "messageText",
                "text": ["text": "Hi"] as [String: Any]
            ] as [String: Any],
            "interaction_info": [
                "reactions": [
                    "@type": "messageReactions",
                    "reactions": [
                        [
                            "type": [
                                "@type": "reactionTypeEmoji",
                                "emoji": "👍"
                            ] as [String: Any],
                            "total_count": 3,
                            "is_chosen": true
                        ] as [String: Any],
                        [
                            "type": [
                                "@type": "reactionTypePaid"
                            ] as [String: Any],
                            "total_count": 1,
                            "is_chosen": false
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]

        let parsed = service.parseMessageInfo(message)
        XCTAssertEqual(parsed?.reactions.count, 2)
        XCTAssertEqual(parsed?.reactions.first?.key, "emoji:👍")
        XCTAssertEqual(parsed?.reactions.first?.emoji, "👍")
        XCTAssertEqual(parsed?.reactions.first?.actionValue, "👍")
        XCTAssertEqual(parsed?.reactions.first?.count, 3)
        XCTAssertEqual(parsed?.reactions.last?.key, "paid")
        XCTAssertEqual(parsed?.reactions.last?.emoji, "⭐")
        XCTAssertNil(parsed?.reactions.last?.actionValue)
    }

    func testParseStickerMessage() {
        let content: [String: Any] = [
            "@type": "messageSticker",
            "sticker": [
                "emoji": "😀",
                "sticker": ["id": 55] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .sticker(let emoji, _, _) = parsed {
            XCTAssertEqual(emoji, "😀")
        } else {
            XCTFail("Expected .sticker, got \(parsed)")
        }
    }

    func testParseCallMessage() {
        let content: [String: Any] = [
            "@type": "messageCall",
            "duration": 120,
            "is_video": false,
            "discard_reason": ["@type": "callDiscardReasonMissed"] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .call(let duration, let isVideo, let reason) = parsed {
            XCTAssertEqual(duration, 120)
            XCTAssertFalse(isVideo)
            XCTAssertEqual(reason, "callDiscardReasonMissed")
        } else {
            XCTFail("Expected .call, got \(parsed)")
        }
    }

    func testParseDocumentMessage() {
        let content: [String: Any] = [
            "@type": "messageDocument",
            "document": [
                "file_name": "report.pdf",
                "document": ["id": 77, "size": 1024] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .document(let name, let size, _) = parsed {
            XCTAssertEqual(name, "report.pdf")
            XCTAssertEqual(size, 1024)
        } else {
            XCTFail("Expected .document, got \(parsed)")
        }
    }

    func testParsePollMessage() {
        let content: [String: Any] = [
            "@type": "messagePoll",
            "poll": [
                "question": ["text": "Favorite color?"] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .poll(let question) = parsed {
            XCTAssertEqual(question, "Favorite color?")
        } else {
            XCTFail("Expected .poll, got \(parsed)")
        }
    }

    func testParseSystemMessages() {
        XCTAssertEqual(MessageContent.parsed(["@type": "messagePinMessage"]), .pinnedMessage)
        XCTAssertEqual(MessageContent.parsed(["@type": "messageChatJoinByLink"]), .memberJoined)
        XCTAssertEqual(MessageContent.parsed(["@type": "messageChatDeleteMember"]), .memberLeft)
        XCTAssertEqual(MessageContent.parsed(["@type": "messageBasicGroupChatCreate"]), .chatCreated)
    }

    func testParseLocationMessage() {
        let content: [String: Any] = [
            "@type": "messageLocation",
            "location": ["latitude": 41.299496, "longitude": 69.240073] as [String: Any],
            "live_period": 0
        ]
        let parsed = MessageContent.parsed(content)
        if case .location(let lat, let lng, let live) = parsed {
            XCTAssertEqual(lat, 41.299496, accuracy: 1e-6)
            XCTAssertEqual(lng, 69.240073, accuracy: 1e-6)
            XCTAssertNil(live)
        } else {
            XCTFail("Expected .location, got \(parsed)")
        }
    }

    func testParseLiveLocationMessage() {
        let content: [String: Any] = [
            "@type": "messageLocation",
            "location": ["latitude": 41.0, "longitude": 69.0] as [String: Any],
            "live_period": 900
        ]
        let parsed = MessageContent.parsed(content)
        if case .location(_, _, let live) = parsed {
            XCTAssertEqual(live, 900)
        } else {
            XCTFail("Expected .location live, got \(parsed)")
        }
    }

    func testParseVenueMessage() {
        let content: [String: Any] = [
            "@type": "messageVenue",
            "venue": [
                "location": ["latitude": 48.8584, "longitude": 2.2945] as [String: Any],
                "title": "Eiffel Tower",
                "address": "Champ de Mars, Paris",
                "type": "travel_lodging"
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        if case .venue(let lat, let lng, let title, let address, let type) = parsed {
            XCTAssertEqual(lat, 48.8584, accuracy: 1e-4)
            XCTAssertEqual(lng, 2.2945, accuracy: 1e-4)
            XCTAssertEqual(title, "Eiffel Tower")
            XCTAssertEqual(address, "Champ de Mars, Paris")
            XCTAssertEqual(type, "travel_lodging")
        } else {
            XCTFail("Expected .venue, got \(parsed)")
        }
    }

    func testVenueIconMapping() {
        XCTAssertEqual(LocationMessageView.icon(for: "arts_entertainment_museum"), "building.columns.fill")
        XCTAssertEqual(LocationMessageView.icon(for: "travel_lodging"), "bed.double.fill")
        XCTAssertEqual(LocationMessageView.icon(for: "food_restaurant"), "fork.knife")
        XCTAssertEqual(LocationMessageView.icon(for: "shop_clothing"), "bag.fill")
        XCTAssertEqual(LocationMessageView.icon(for: "outdoor_park"), "tree.fill")
        XCTAssertEqual(LocationMessageView.icon(for: "transport_station"), "tram.fill")
        XCTAssertEqual(LocationMessageView.icon(for: "unknown_blob"), "mappin.circle.fill")
        XCTAssertEqual(LocationMessageView.icon(for: nil), "mappin.circle.fill")
    }

    func testParseUnsupportedMessage() {
        let content: [String: Any] = ["@type": "messageUnknownType"]
        let parsed = MessageContent.parsed(content)
        if case .unsupported(let type) = parsed {
            XCTAssertEqual(type, "UnknownType")
        } else {
            XCTFail("Expected .unsupported")
        }
    }

    func testParseNilContent() {
        let parsed = MessageContent.parsed(nil)
        if case .unsupported = parsed {
            // OK
        } else {
            XCTFail("Expected .unsupported for nil content")
        }
    }

    // MARK: - ReactionInfo(tdApi:)

    private func reaction(_ dict: [String: Any]) -> ReactionInfo? {
        ReactionInfo(tdApi: TDApi.decodeMessageReaction(dict))
    }

    func testParseReaction() {
        let dict: [String: Any] = [
            "type": ["@type": "reactionTypeEmoji", "emoji": "👍"] as [String: Any],
            "total_count": 3,
            "is_chosen": true
        ]
        let parsed = reaction(dict)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.emoji, "👍")
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertTrue(parsed?.isSelected ?? false)
    }

    func testParseReactionMissingEmoji() {
        let unknownKind: [String: Any] = [
            "type": ["@type": "reactionTypeSomething"] as [String: Any],
            "total_count": 1
        ]
        let emptyEmoji: [String: Any] = [
            "type": ["@type": "reactionTypeEmoji"] as [String: Any],
            "total_count": 1
        ]
        let noType: [String: Any] = ["total_count": 1]

        XCTAssertNil(reaction(unknownKind))
        XCTAssertNil(reaction(emptyEmoji))
        XCTAssertNil(reaction(noType))
    }

    // MARK: - extractDraftText

    func testExtractDraftText() {
        let dict: [String: Any] = [
            "draft_message": [
                "input_message_text": [
                    "text": [
                        "text": "My draft"
                    ]
                ]
            ]
        ]
        XCTAssertEqual(service.extractDraftText(from: dict), "My draft")
    }

    func testExtractDraftTextEmpty() {
        let dict: [String: Any] = [
            "draft_message": [
                "input_message_text": [
                    "text": [
                        "text": ""
                    ]
                ]
            ]
        ]
        XCTAssertNil(service.extractDraftText(from: dict))
    }

    func testExtractDraftTextMissing() {
        let dict: [String: Any] = [:]
        XCTAssertNil(service.extractDraftText(from: dict))
    }

    // MARK: - toInt64

    func testToInt64FromInt() {
        XCTAssertEqual(service.toInt64(42), 42)
    }

    func testToInt64FromString() {
        XCTAssertEqual(service.toInt64("123"), 123)
    }

    func testToInt64FromDouble() {
        XCTAssertEqual(service.toInt64(3.14), 3)
    }

    func testToInt64FromNil() {
        XCTAssertEqual(service.toInt64(nil), 0)
    }

    // MARK: - parseContactInfo

    func testParseContactInfo() {
        let user: [String: Any] = [
            "id": 456,
            "first_name": "John",
            "last_name": "Doe",
            "phone_number": "+15551234567",
            "usernames": ["editable_username": "johndoe"] as [String: Any],
            "status": ["@type": "userStatusOnline"] as [String: Any]
        ]
        let contact = service.parseContactInfo(user)
        XCTAssertEqual(contact.id, 456)
        XCTAssertEqual(contact.firstName, "John")
        XCTAssertEqual(contact.lastName, "Doe")
        XCTAssertEqual(contact.phone, "+15551234567")
        XCTAssertEqual(contact.username, "johndoe")
        XCTAssertTrue(contact.isOnline)
    }

    // MARK: - parseFolderTitle

    func testParseFolderTitlePlainString() {
        let info: [String: Any] = ["id": 1, "title": "Work"]
        XCTAssertEqual(service.parseFolderTitle(info), "Work")
    }

    func testParseFolderTitleFormattedText() {
        let info: [String: Any] = [
            "id": 2,
            "title": ["text": "Personal"] as [String: Any]
        ]
        XCTAssertEqual(service.parseFolderTitle(info), "Personal")
    }

    func testParseFolderTitleNestedText() {
        let info: [String: Any] = [
            "id": 3,
            "name": ["text": ["text": "Channels"] as [String: Any]] as [String: Any]
        ]
        XCTAssertEqual(service.parseFolderTitle(info), "Channels")
    }
}
