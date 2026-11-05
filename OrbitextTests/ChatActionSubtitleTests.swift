import XCTest
@testable import OrbitextWatch

/// The line under the title while someone acts in the chat.
final class ChatActionSubtitleTests: XCTestCase {
    func testNothingIsShownWithoutAnActionOrAnActor() {
        XCTAssertNil(ChatActionSubtitle.text(for: chat()))
        XCTAssertNil(ChatActionSubtitle.text(for: chat(kind: .typing, names: [])))
        XCTAssertNil(ChatActionSubtitle.text(for: chat(kind: .none, names: ["Alice"])))
    }

    func testTypingNamesTheActorsUpToTwoThenCountsThem() {
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .typing, names: ["Alice"])),
                       L10n.format("%@ typing...", "Alice"))
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .typing, names: ["Alice", "Bob"])),
                       L10n.format("%@, %@ typing...", "Alice", "Bob"))
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .typing, names: ["Alice", "Bob", "Eve"])),
                       L10n.format("%lld people typing...", Int64(3)))
    }

    /// A private chat's title already names the other side; a group names who acts.
    func testOtherActionsNameTheActorOnlyInGroups() {
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .recordingVoice, names: ["Alice"])),
                       L10n.string("recording voice..."))
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .recordingVoice, names: ["Alice"], isGroup: true)),
                       L10n.format("%@ is recording voice...", "Alice"))
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .uploadingPhoto, names: ["Alice"], isGroup: true)),
                       L10n.format("%@ is uploading photo...", "Alice"))
    }

    func testAChannelNeverNamesTheActor() {
        XCTAssertEqual(ChatActionSubtitle.text(for: chat(kind: .uploadingDocument, names: ["Alice"], isGroup: true, isChannel: true)),
                       L10n.string("sending file..."))
    }

    private func chat(
        kind: ChatActionKind = .none, names: [String] = [], isGroup: Bool = false, isChannel: Bool = false
    ) -> ChatInfo {
        var chat = ChatInfo(id: 1, title: "Chat", lastMessage: nil, unreadCount: 0, isGroup: isGroup, isMuted: false, order: 0)
        chat.isChannel = isChannel
        chat.typingActionKind = kind
        chat.typingUserNames = names
        return chat
    }
}
