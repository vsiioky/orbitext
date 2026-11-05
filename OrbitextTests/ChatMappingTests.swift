import XCTest
@testable import OrbitextWatch

/// Parity tests: the new typed `parseChatInfoTyped` must produce
/// the same `ChatInfo` as the legacy dict-walker for the inputs we have
/// historically supported. Both paths are exercised against the same
/// dictionary so any drift surfaces immediately.
final class ChatMappingTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Parity helper

    private func assertParity(
        _ dict: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ChatInfo {
        guard let typed = service.parseChatInfoTyped(dict) else {
            XCTFail("typed path returned nil", file: file, line: line)
            return service.parseChatInfo(dict)
        }
        // Run the legacy dict-walk via a copy of the dict so we are not
        // mutated by either side. parseChatInfo prefers the typed path,
        // so to compare we re-derive the legacy result by stripping the
        // typed-path entry conditions. We snapshot fields one at a time.
        let legacy = legacyParseChatInfo(dict)
        XCTAssertEqual(typed.id, legacy.id, "id", file: file, line: line)
        XCTAssertEqual(typed.title, legacy.title, "title", file: file, line: line)
        XCTAssertEqual(typed.unreadCount, legacy.unreadCount, "unreadCount", file: file, line: line)
        XCTAssertEqual(typed.mentionCount, legacy.mentionCount, "mentionCount", file: file, line: line)
        XCTAssertEqual(typed.reactionCount, legacy.reactionCount, "reactionCount", file: file, line: line)
        XCTAssertEqual(typed.isGroup, legacy.isGroup, "isGroup", file: file, line: line)
        XCTAssertEqual(typed.isChannel, legacy.isChannel, "isChannel", file: file, line: line)
        XCTAssertEqual(typed.isMuted, legacy.isMuted, "isMuted", file: file, line: line)
        XCTAssertEqual(typed.order, legacy.order, "order", file: file, line: line)
        XCTAssertEqual(typed.isPinned, legacy.isPinned, "isPinned", file: file, line: line)
        XCTAssertEqual(typed.photoFileId, legacy.photoFileId, "photoFileId", file: file, line: line)
        XCTAssertEqual(typed.draftMessage, legacy.draftMessage, "draftMessage", file: file, line: line)
        XCTAssertEqual(typed.isOnline, legacy.isOnline, "isOnline", file: file, line: line)
        XCTAssertEqual(typed.lastReadOutboxMessageId, legacy.lastReadOutboxMessageId, "lastReadOutboxMessageId", file: file, line: line)
        XCTAssertEqual(typed.lastMessage?.id, legacy.lastMessage?.id, "lastMessage.id", file: file, line: line)
        return typed
    }

    /// Inlines the legacy dict-walk for the parity comparison so we keep
    /// reading the field-by-field semantics even after the
    /// fallback in parseChatInfo is deleted. Mirrors the original body.
    private func legacyParseChatInfo(_ dict: [String: Any]) -> ChatInfo {
        let id = service.toInt64(dict["id"])
        var title = dict["title"] as? String ?? ""
        let unreadCount = dict["unread_count"] as? Int ?? 0
        let mentionCount = dict["unread_mention_count"] as? Int ?? 0
        let reactionCount = dict["unread_reaction_count"] as? Int ?? 0
        let position = (dict["positions"] as? [[String: Any]])?.first {
            ($0["list"] as? [String: Any])?["@type"] as? String == "chatListMain"
        }
        let order = service.toInt64(position?["order"] ?? dict["order"])
        let isPinned = position?["is_pinned"] as? Bool ?? false

        var photoFileId: String? = nil
        if let photo = dict["photo"] as? [String: Any],
           let small = photo["small"] as? [String: Any] {
            photoFileId = "\(service.toInt64(small["id"]))"
        }

        let chatType = dict["type"] as? [String: Any]
        let typeStr = chatType?["@type"] as? String ?? ""
        let isSupergroupChannel = typeStr == "chatTypeSupergroup" && chatType?["is_channel"] as? Bool == true
        let isGroup = (typeStr == "chatTypeBasicGroup" || typeStr == "chatTypeSupergroup") && !isSupergroupChannel

        var isOnline = false
        if typeStr == "chatTypePrivate" {
            let userId = service.toInt64(chatType?["user_id"])
            if userId != 0 && userId == service.myUserId {
                title = L10n.string("Saved Messages")
            }
            isOnline = service.userCache.get(userId)?.status.isOnline ?? false
        }

        let notifSettings = service.normalizeDictionary(dict["notification_settings"])
        let isMuted = service.toInt64(notifSettings?["mute_for"]) > 0

        var lastMessage: MessageInfo? = nil
        if let rawMsg = dict["last_message"] as? [String: Any] {
            lastMessage = service.parseMessageInfo(rawMsg)
        }

        let draftText = service.extractDraftText(from: dict)
        let lastReadOutbox = service.toInt64(dict["last_read_outbox_message_id"])

        return ChatInfo(
            id: id,
            title: title,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            photoFileId: photoFileId,
            isGroup: isGroup,
            isChannel: isSupergroupChannel,
            isMuted: isMuted,
            order: order,
            isPinned: isPinned,
            draftMessage: draftText,
            isOnline: isOnline,
            lastReadOutboxMessageId: lastReadOutbox,
            mentionCount: mentionCount,
            reactionCount: reactionCount
        )
    }

    // MARK: - Tests

    func testPrivateChatBasic() {
        let info = assertParity([
            "id": 123,
            "title": "Alice",
            "unread_count": 5,
            "type": ["@type": "chatTypePrivate", "user_id": 456] as [String: Any]
        ])
        XCTAssertEqual(info.id, 123)
        XCTAssertFalse(info.isGroup)
        XCTAssertFalse(info.isChannel)
    }

    func testBasicGroupIsGroup() {
        let info = assertParity([
            "id": 10,
            "title": "Group",
            "type": ["@type": "chatTypeBasicGroup", "basic_group_id": 7] as [String: Any]
        ])
        XCTAssertTrue(info.isGroup)
        XCTAssertFalse(info.isChannel)
    }

    func testSupergroupNonChannelIsGroup() {
        let info = assertParity([
            "id": 11,
            "title": "Super",
            "type": ["@type": "chatTypeSupergroup", "supergroup_id": 99, "is_channel": false] as [String: Any]
        ])
        XCTAssertTrue(info.isGroup)
        XCTAssertFalse(info.isChannel)
    }

    func testSupergroupChannelIsChannel() {
        let info = assertParity([
            "id": 12,
            "title": "News",
            "type": ["@type": "chatTypeSupergroup", "supergroup_id": 99, "is_channel": true] as [String: Any]
        ])
        XCTAssertFalse(info.isGroup)
        XCTAssertTrue(info.isChannel)
    }

    func testPositionsEmptyOrderIsZero() {
        let info = assertParity([
            "id": 20,
            "title": "Empty positions",
            "type": ["@type": "chatTypePrivate", "user_id": 20] as [String: Any]
        ])
        XCTAssertEqual(info.order, 0)
        XCTAssertFalse(info.isPinned)
    }

    func testPositionsNonMainListIsSkipped() {
        let info = assertParity([
            "id": 21,
            "title": "Folder only",
            "type": ["@type": "chatTypePrivate", "user_id": 21] as [String: Any],
            "positions": [
                [
                    "@type": "chatPosition",
                    "list": ["@type": "chatListFolder", "chat_folder_id": 3] as [String: Any],
                    "order": 42,
                    "is_pinned": true
                ] as [String: Any]
            ]
        ])
        XCTAssertEqual(info.order, 0)
        XCTAssertFalse(info.isPinned)
    }

    func testPositionsMainListWins() {
        let info = assertParity([
            "id": 22,
            "title": "Pinned",
            "type": ["@type": "chatTypePrivate", "user_id": 22] as [String: Any],
            "positions": [
                [
                    "@type": "chatPosition",
                    "list": ["@type": "chatListFolder", "chat_folder_id": 1] as [String: Any],
                    "order": 5,
                    "is_pinned": false
                ] as [String: Any],
                [
                    "@type": "chatPosition",
                    "list": ["@type": "chatListMain"] as [String: Any],
                    "order": 99,
                    "is_pinned": true
                ] as [String: Any]
            ]
        ])
        XCTAssertEqual(info.order, 99)
        XCTAssertTrue(info.isPinned)
    }

    func testNotificationSettingsMuteForFlagsMuted() {
        let info = assertParity([
            "id": 30,
            "title": "Muted",
            "type": ["@type": "chatTypePrivate", "user_id": 30] as [String: Any],
            "notification_settings": ["mute_for": 2147483647] as [String: Any]
        ])
        XCTAssertTrue(info.isMuted)
    }

    func testNotificationSettingsMuteForZeroIsUnmuted() {
        let info = assertParity([
            "id": 31,
            "title": "Unmuted",
            "type": ["@type": "chatTypePrivate", "user_id": 31] as [String: Any],
            "notification_settings": ["mute_for": 0, "use_default_mute_for": true] as [String: Any]
        ])
        XCTAssertFalse(info.isMuted)
    }

    func testDraftMessageNonEmpty() {
        let info = assertParity([
            "id": 40,
            "title": "Draft",
            "type": ["@type": "chatTypePrivate", "user_id": 40] as [String: Any],
            "draft_message": [
                "@type": "draftMessage",
                "reply_to_message_id": 555,
                "input_message_text": [
                    "@type": "inputMessageText",
                    "text": ["@type": "formattedText", "text": "hello world"] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ])
        XCTAssertEqual(info.draftMessage, "hello world")
        XCTAssertTrue(info.hasDraft)
    }

    func testDraftMessageEmptyTextIsNil() {
        let info = assertParity([
            "id": 41,
            "title": "EmptyDraft",
            "type": ["@type": "chatTypePrivate", "user_id": 41] as [String: Any],
            "draft_message": [
                "@type": "draftMessage",
                "reply_to_message_id": 0,
                "input_message_text": [
                    "@type": "inputMessageText",
                    "text": ["@type": "formattedText", "text": ""] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ])
        XCTAssertNil(info.draftMessage)
    }

    func testPhotoFileIdFromSmall() {
        let info = assertParity([
            "id": 50,
            "title": "Photo",
            "type": ["@type": "chatTypePrivate", "user_id": 50] as [String: Any],
            "photo": [
                "@type": "chatPhotoInfo",
                "small": [
                    "@type": "file",
                    "id": 8888,
                    "size": 0,
                    "expected_size": 0
                ] as [String: Any]
            ] as [String: Any]
        ])
        XCTAssertEqual(info.photoFileId, "8888")
    }

    func testUnreadReactionCountFlowsFromDict() {
        let info = assertParity([
            "id": 60,
            "title": "Reactions",
            "type": ["@type": "chatTypePrivate", "user_id": 60] as [String: Any],
            "unread_reaction_count": 3
        ])
        XCTAssertEqual(info.reactionCount, 3)
    }

    func testMentionCountFromTypedPath() {
        let info = assertParity([
            "id": 61,
            "title": "Mentions",
            "type": ["@type": "chatTypePrivate", "user_id": 61] as [String: Any],
            "unread_mention_count": 4
        ])
        XCTAssertEqual(info.mentionCount, 4)
    }

    func testLastReadOutboxMessageId() {
        let info = assertParity([
            "id": 70,
            "title": "ReadOutbox",
            "type": ["@type": "chatTypePrivate", "user_id": 70] as [String: Any],
            "last_read_outbox_message_id": 123456789
        ])
        XCTAssertEqual(info.lastReadOutboxMessageId, 123456789)
    }

    func testSavedMessagesTitleOverrideForOwnPrivateChat() {
        service.myUserId = 999
        let info = assertParity([
            "id": 999,
            "title": "Whatever",
            "type": ["@type": "chatTypePrivate", "user_id": 999] as [String: Any]
        ])
        XCTAssertEqual(info.title, L10n.string("Saved Messages"))
    }

    func testSecretChatNotGroupNotChannel() {
        let info = assertParity([
            "id": 80,
            "title": "Secret",
            "type": ["@type": "chatTypeSecret", "secret_chat_id": 1, "user_id": 2] as [String: Any]
        ])
        XCTAssertFalse(info.isGroup)
        XCTAssertFalse(info.isChannel)
    }
}
