import XCTest
@testable import OrbitextWatch

/// handleUpdateTyped dispatch. Verifies the typed path covers the leaf
/// updates (delete/edit/content-opened/unread counts/chat field mutations/
/// connection/user status) and that complex updates which still need
/// MessageInfo/ChatInfo/UserInfo mapping fall through to the
/// dict-based handlers (return false).
final class UpdateMappingTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Helpers

    private func nextEvent(timeout: TimeInterval = 1.0) async -> TDLibEvent? {
        await withTaskGroup(of: TDLibEvent?.self) { group in
            group.addTask { [events = service.events] in
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func handle(_ dict: [String: Any]) -> Bool {
        service.handleUpdateTyped(dict)
    }

    // MARK: - Leaf updates: typed path

    func testUpdateDeleteMessagesTypedEmitsAndReturnsTrue() async {
        let dict: [String: Any] = [
            "@type": "updateDeleteMessages",
            "chat_id": 555,
            "message_ids": [10, 11, 12],
            "is_permanent": true,
            "from_cache": false
        ]
        XCTAssertTrue(handle(dict))
        guard case .deleteMessages(let chatId, let ids) = await nextEvent() else {
            return XCTFail("expected .deleteMessages")
        }
        XCTAssertEqual(chatId, 555)
        XCTAssertEqual(ids, [10, 11, 12])
    }

    func testUpdateDeleteMessagesNonPermanentSwallowed() {
        // Non-permanent delete still consumed by typed path but emits nothing.
        let dict: [String: Any] = [
            "@type": "updateDeleteMessages",
            "chat_id": 100,
            "message_ids": [1],
            "is_permanent": false,
            "from_cache": true
        ]
        XCTAssertTrue(handle(dict))
    }

    func testUpdateMessageContentOpenedTyped() async {
        let dict: [String: Any] = [
            "@type": "updateMessageContentOpened",
            "chat_id": 7,
            "message_id": 88
        ]
        XCTAssertTrue(handle(dict))
        guard case .messageContentOpened(let chatId, let messageId) = await nextEvent() else {
            return XCTFail("expected .messageContentOpened")
        }
        XCTAssertEqual(chatId, 7)
        XCTAssertEqual(messageId, 88)
    }

    func testUpdateMessageEditedTypedInvalidatesProperties() async {
        let dict: [String: Any] = [
            "@type": "updateMessageEdited",
            "chat_id": 3,
            "message_id": 9,
            "edit_date": 1700000000,
            "reply_markup": NSNull()
        ]
        XCTAssertTrue(handle(dict))
        guard case .messagePropertiesInvalidated(let chatId, let messageId) = await nextEvent() else {
            return XCTFail("expected .messagePropertiesInvalidated")
        }
        XCTAssertEqual(chatId, 3)
        XCTAssertEqual(messageId, 9)
    }

    func testUpdateMessageContentTypedInvalidatesProperties() async {
        let dict: [String: Any] = [
            "@type": "updateMessageContent",
            "chat_id": 4,
            "message_id": 5,
            "new_content": ["@type": "messageText", "text": ["@type": "formattedText", "text": "hi"]] as [String: Any]
        ]
        XCTAssertTrue(handle(dict))
        guard case .messagePropertiesInvalidated(let chatId, let messageId) = await nextEvent() else {
            return XCTFail("expected .messagePropertiesInvalidated")
        }
        XCTAssertEqual(chatId, 4)
        XCTAssertEqual(messageId, 5)
    }

    func testUpdateChatUnreadMentionCountTyped() async {
        let dict: [String: Any] = [
            "@type": "updateChatUnreadMentionCount",
            "chat_id": 42,
            "unread_mention_count": 3
        ]
        XCTAssertTrue(handle(dict))
        guard case .chatMentionCountChanged(let chatId, let count) = await nextEvent() else {
            return XCTFail("expected .chatMentionCountChanged")
        }
        XCTAssertEqual(chatId, 42)
        XCTAssertEqual(count, 3)
    }

    func testUpdateConnectionStateTyped() async {
        let dict: [String: Any] = [
            "@type": "updateConnectionState",
            "state": ["@type": "connectionStateReady"] as [String: Any]
        ]
        XCTAssertTrue(handle(dict))
        guard case .connectionStateChanged(let phase) = await nextEvent() else {
            return XCTFail("expected .connectionStateChanged")
        }
        XCTAssertEqual(phase, TDLibConnectionPhase(rawTDLibState: "connectionStateReady"))
    }

    // MARK: - Updates that still need dict fallback

    func testUpdateNewChatFallsThrough() {
        let dict: [String: Any] = [
            "@type": "updateNewChat",
            "chat": ["id": 1, "title": "X"] as [String: Any]
        ]
        // The typed path does not cover chat updates yet, so it defers.
        XCTAssertFalse(handle(dict))
    }

    func testUpdateNewMessageFallsThrough() {
        let dict: [String: Any] = [
            "@type": "updateNewMessage",
            "message": ["id": 1, "chat_id": 1] as [String: Any]
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUpdateUserFallsThrough() {
        let dict: [String: Any] = [
            "@type": "updateUser",
            "user": ["id": 1, "first_name": "A"] as [String: Any]
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUpdateFileFallsThrough() {
        let dict: [String: Any] = [
            "@type": "updateFile",
            "file": ["id": 7] as [String: Any]
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUpdateAuthorizationStateFallsThrough() {
        // Auth flow has rich side effects in handleAuthUpdate; it stays
        // on the dict path until the AuthState mapping is broken out.
        let dict: [String: Any] = [
            "@type": "updateAuthorizationState",
            "authorization_state": ["@type": "authorizationStateReady"] as [String: Any]
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUpdateChatActionFallsThrough() {
        let dict: [String: Any] = [
            "@type": "updateChatAction",
            "chat_id": 1,
            "message_thread_id": 0,
            "sender_id": ["@type": "messageSenderUser", "user_id": 42] as [String: Any],
            "action": ["@type": "chatActionTyping"] as [String: Any]
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUpdateChatUnreadReactionCountFallsThrough() {
        // Not among the updates in scripts/codegen-roots.txt, so the typed
        // path bows out and the dict handler runs.
        let dict: [String: Any] = [
            "@type": "updateChatUnreadReactionCount",
            "chat_id": 9,
            "unread_reaction_count": 2
        ]
        XCTAssertFalse(handle(dict))
    }

    func testUnknownAtTypeFallsThrough() {
        let dict: [String: Any] = ["@type": "updateNotARealEvent"]
        XCTAssertFalse(handle(dict))
    }

    func testComplexInitialSyncUpdatesStayOnLegacyPath() async {
        let message: [String: Any] = [
            "id": 11, "chat_id": 42,
            "content": ["@type": "messageText", "text": ["text": "hello", "entities": []]]
        ]
        for type in [
            "updateNewChat", "updateNewMessage", "updateChatLastMessage",
            "updateMessageSendSucceeded", "updateMessageSendFailed",
            "updateChatDraftMessage", "updateUser", "updateNotificationGroup"
        ] {
            XCTAssertFalse(handle([
                "@type": type, "chat_id": 42, "message": message,
                "last_message": message, "chat": ["id": 42, "last_message": message]
            ]), type)
        }
        service.session.finishEventsForTesting()
        for await _ in service.events { XCTFail("typed fallback must not emit events") }
    }

    // MARK: - ChatActionKind(tdApi:)

    func testChatActionKindMapsAllKnownVariants() {
        let cases: [(TDApi.ChatAction, ChatActionKind)] = [
            (.chatActionTyping(.init()), .typing),
            (.chatActionRecordingVoiceNote(.init()), .recordingVoice),
            (.chatActionUploadingVoiceNote(.init(progress: 0)), .uploadingVoice),
            (.chatActionRecordingVideoNote(.init()), .recordingVideo),
            (.chatActionUploadingVideoNote(.init(progress: 0)), .uploadingVideoNote),
            (.chatActionUploadingPhoto(.init(progress: 0)), .uploadingPhoto),
            (.chatActionUploadingVideo(.init(progress: 0)), .uploadingVideo),
            (.chatActionUploadingDocument(.init(progress: 0)), .uploadingDocument),
            (.chatActionChoosingSticker(.init()), .choosingSticker),
            (.chatActionChoosingLocation(.init()), .choosingLocation),
            (.chatActionChoosingContact(.init()), .choosingContact),
            (.chatActionStartPlayingGame(.init()), .playingGame),
            (.chatActionWatchingAnimations(.init(emoji: "")), .none),
            (.chatActionCancel(.init()), .none),
            (.unknown(tag: "weird"), .none)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ChatActionKind(tdApi: input), expected, "mapping for \(input)")
        }
        XCTAssertEqual(ChatActionKind(tdApi: nil), .none)
    }
}
