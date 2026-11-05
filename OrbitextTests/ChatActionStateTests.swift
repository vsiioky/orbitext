import XCTest
@testable import OrbitextWatch

final class ChatActionStateTests: XCTestCase {
    private let origin = ContinuousClock.now

    func testMissingChatHasEmptySnapshot() {
        assertSnapshot(ChatActionState(), chatId: 1, names: [], kind: .none)
    }

    func testKnownActionsUpdateSenderAndKind() throws {
        let cases: [(String, ChatActionKind)] = [
            ("chatActionTyping", .typing),
            ("chatActionRecordingVoiceNote", .recordingVoice),
            ("chatActionUploadingVoiceNote", .uploadingVoice),
            ("chatActionRecordingVideoNote", .recordingVideo),
            ("chatActionUploadingVideoNote", .uploadingVideoNote),
            ("chatActionUploadingPhoto", .uploadingPhoto),
            ("chatActionUploadingVideo", .uploadingVideo),
            ("chatActionUploadingDocument", .uploadingDocument),
            ("chatActionChoosingSticker", .choosingSticker),
            ("chatActionChoosingLocation", .choosingLocation),
            ("chatActionChoosingContact", .choosingContact),
            ("chatActionStartPlayingGame", .playingGame)
        ]
        var state = ChatActionState()

        for (actionType, kind) in cases {
            let result = try XCTUnwrap(apply(&state, name: "Alice", actionType: actionType))
            XCTAssertEqual(result.names, ["Alice"], actionType)
            XCTAssertEqual(result.kind, kind, actionType)
        }
    }

    func testSenderNameIsReplacedWithoutAddingAnotherUser() {
        var state = ChatActionState()
        apply(&state, name: "Old name")
        apply(&state, name: "New name")

        assertSnapshot(state, chatId: 1, names: ["New name"], kind: .typing)
    }

    func testLastActionWinsAcrossSendersWithoutChangingOtherChats() {
        var state = ChatActionState()
        apply(&state, chatId: 2, name: "Other chat", actionType: "chatActionChoosingSticker")
        apply(&state, senderId: 10, name: "Alice", actionType: "chatActionRecordingVoiceNote")
        apply(&state, senderId: 20, name: "Bob", actionType: "chatActionUploadingPhoto")

        assertSnapshot(state, chatId: 1, names: ["Alice", "Bob"], kind: .uploadingPhoto)
        assertSnapshot(state, chatId: 2, names: ["Other chat"], kind: .choosingSticker)
    }

    func testCancelOneSenderPreservesLastActionKind() throws {
        var state = ChatActionState()
        apply(&state, senderId: 10, name: "Alice")
        apply(&state, senderId: 20, name: "Bob", actionType: "chatActionRecordingVoiceNote")

        let result = try XCTUnwrap(apply(&state, senderId: 20, actionType: "chatActionCancel"))

        XCTAssertEqual(result.names, ["Alice"])
        XCTAssertEqual(result.kind, .recordingVoice)
        assertSnapshot(state, chatId: 1, names: ["Alice"], kind: .recordingVoice)
    }

    func testCancelLastSenderClearsChatAndNextActionStartsFresh() throws {
        var state = ChatActionState()
        apply(&state, name: "Alice", actionType: "chatActionUploadingDocument")

        let result = try XCTUnwrap(apply(&state, actionType: "chatActionCancel"))

        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.kind, .none)
        assertSnapshot(state, chatId: 1, names: [], kind: .none)
        apply(&state, senderId: 20, name: "Bob")
        assertSnapshot(state, chatId: 1, names: ["Bob"], kind: .typing)
    }

    func testCancelUnknownSenderReturnsUnchangedSnapshot() throws {
        var state = ChatActionState()
        apply(&state, senderId: 10, name: "Alice", actionType: "chatActionRecordingVideoNote")

        let result = try XCTUnwrap(apply(&state, senderId: 99, actionType: "chatActionCancel"))

        XCTAssertEqual(result.names, ["Alice"])
        XCTAssertEqual(result.kind, .recordingVideo)
        assertSnapshot(state, chatId: 1, names: ["Alice"], kind: .recordingVideo)
    }

    func testCancelMissingChatReturnsEmptySnapshot() throws {
        var state = ChatActionState()

        let result = try XCTUnwrap(apply(&state, actionType: "chatActionCancel"))

        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.kind, .none)
        assertSnapshot(state, chatId: 1, names: [], kind: .none)
    }

    func testUnknownActionIsIgnoredRatherThanCancellingOrReplacingSender() {
        var state = ChatActionState()
        apply(&state, name: "Alice", actionType: "chatActionRecordingVoiceNote")

        for actionType in ["", "unknownAction", "chatActionTyping ", "chatActionCancelUnknown"] {
            XCTAssertNil(apply(&state, name: "Changed", actionType: actionType))
            assertSnapshot(state, chatId: 1, names: ["Alice"], kind: .recordingVoice)
            XCTAssertNil(apply(&state, chatId: 2, actionType: actionType))
            assertSnapshot(state, chatId: 2, names: [], kind: .none)
        }
    }

    func testCapacityEvictsOldestTimestampRatherThanLowestChatId() {
        var state = ChatActionState()
        // Higher chat IDs have older timestamps, independent of insertion order.
        for chatId in Int64(1)...50 {
            apply(&state, chatId: chatId, at: 51 - chatId)
        }
        XCTAssertEqual(activeChatCount(state, in: 1...50), 50)

        apply(&state, chatId: 51, at: 100)
        apply(&state, chatId: 52, at: 101)

        XCTAssertEqual(activeChatCount(state, in: 1...52), 50)
        assertSnapshot(state, chatId: 49, names: [], kind: .none)
        assertSnapshot(state, chatId: 50, names: [], kind: .none)
        assertSnapshot(state, chatId: 1, names: ["Alice"], kind: .typing)
        assertSnapshot(state, chatId: 52, names: ["Alice"], kind: .typing)
    }

    func testNewActionRefreshesRecencyBeforeEviction() {
        var state = filledState()
        apply(&state, chatId: 1, name: "Updated", actionType: "chatActionUploadingPhoto", at: 100)

        apply(&state, chatId: 51, at: 101)

        XCTAssertEqual(activeChatCount(state, in: 1...51), 50)
        assertSnapshot(state, chatId: 1, names: ["Updated"], kind: .uploadingPhoto)
        assertSnapshot(state, chatId: 2, names: [], kind: .none)
    }

    func testPartialCancelDoesNotRefreshRecency() {
        var state = ChatActionState()
        apply(&state, chatId: 1, senderId: 20, name: "Bob", at: 0)
        for chatId in Int64(1)...50 {
            apply(&state, chatId: chatId, at: chatId)
        }
        apply(&state, chatId: 1, senderId: 20, actionType: "chatActionCancel", at: 100)

        apply(&state, chatId: 51, at: 101)

        assertSnapshot(state, chatId: 1, names: [], kind: .none)
        assertSnapshot(state, chatId: 2, names: ["Alice"], kind: .typing)
    }

    func testIgnoredActionDoesNotRefreshRecency() {
        var state = filledState()
        XCTAssertNil(apply(&state, chatId: 1, actionType: "unknownAction", at: 100))

        apply(&state, chatId: 51, at: 101)

        assertSnapshot(state, chatId: 1, names: [], kind: .none)
        assertSnapshot(state, chatId: 2, names: ["Alice"], kind: .typing)
    }

    func testCurrentChatIsProtectedDuringEviction() {
        var state = filledState()

        // Force the current chat to look oldest to exercise its explicit protection.
        apply(&state, chatId: 51, name: "Current", at: 0)

        XCTAssertEqual(activeChatCount(state, in: 1...51), 50)
        assertSnapshot(state, chatId: 51, names: ["Current"], kind: .typing)
        assertSnapshot(state, chatId: 1, names: [], kind: .none)
    }

    func testResetRemovesAllChatStateAndCapacityIsReusable() {
        var state = filledState()

        state.reset()

        XCTAssertEqual(activeChatCount(state, in: 1...50), 0)
        for chatId in Int64(51)...100 {
            apply(&state, chatId: chatId, actionType: "chatActionChoosingSticker", at: chatId)
        }
        XCTAssertEqual(activeChatCount(state, in: 1...100), 50)
        assertSnapshot(state, chatId: 51, names: ["Alice"], kind: .choosingSticker)
        assertSnapshot(state, chatId: 100, names: ["Alice"], kind: .choosingSticker)
    }

    @discardableResult
    private func apply(
        _ state: inout ChatActionState,
        chatId: Int64 = 1,
        senderId: Int64 = 10,
        name: String = "Alice",
        actionType: String = "chatActionTyping",
        at seconds: Int64 = 0
    ) -> ChatActionState.Snapshot? {
        state.apply(
            chatId: chatId,
            senderId: senderId,
            name: name,
            actionType: actionType,
            at: origin.advanced(by: .seconds(seconds))
        )
    }

    private func filledState() -> ChatActionState {
        var state = ChatActionState()
        for chatId in Int64(1)...50 {
            apply(&state, chatId: chatId, at: chatId)
        }
        return state
    }

    private func activeChatCount(_ state: ChatActionState, in range: ClosedRange<Int64>) -> Int {
        range.filter { !state.snapshot(for: $0).names.isEmpty }.count
    }

    private func assertSnapshot(
        _ state: ChatActionState,
        chatId: Int64,
        names: [String],
        kind: ChatActionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = state.snapshot(for: chatId)
        XCTAssertEqual(snapshot.names.sorted(), names.sorted(), file: file, line: line)
        XCTAssertEqual(snapshot.kind, kind, file: file, line: line)
    }
}
