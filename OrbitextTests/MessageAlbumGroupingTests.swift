import SwiftUI
import XCTest
@testable import OrbitextWatch

final class MessageAlbumGroupingTests: XCTestCase {
    @MainActor
    func testReactionLayoutUsesContentWidth() throws {
        let renderer = ImageRenderer(content: FlowLayout {
            Color.red.frame(width: 28, height: 16)
        })
        renderer.proposedSize = ProposedViewSize(width: 180, height: nil)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 28)
        XCTAssertEqual(image.height, 16)
    }

    @MainActor
    func testReactionLayoutStillWrapsWithinAvailableWidth() throws {
        let renderer = ImageRenderer(content: FlowLayout(spacing: 4, lineSpacing: 3) {
            ForEach(0..<3) { _ in
                Color.red.frame(width: 28, height: 16)
            }
        })
        renderer.proposedSize = ProposedViewSize(width: 60, height: nil)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 60)
        XCTAssertEqual(image.height, 35)
    }

    private func makeMessage(
        id: Int64,
        albumId: Int64 = 0,
        content: MessageContent? = nil,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MessageInfo {
        let resolvedContent = content ?? .photo(caption: "", fileId: "f\(id)", width: 100, height: 100, minithumbnail: nil)
        return MessageInfo(
            id: id,
            chatId: 1,
            senderName: "Sender",
            senderId: 42,
            content: resolvedContent,
            date: date,
            isOutgoing: false,
            isRead: false,
            mediaAlbumId: albumId
        )
    }

    func testGroupsThreeMessagesWithSameAlbumId() {
        let messages = [
            makeMessage(id: 1, albumId: 100),
            makeMessage(id: 2, albumId: 100),
            makeMessage(id: 3, albumId: 100)
        ]

        let items = MessageAlbumInfo.group(messages)

        XCTAssertEqual(items.count, 1)
        if case .album(let album) = items[0] {
            XCTAssertEqual(album.albumId, 100)
            XCTAssertEqual(album.messages.map(\.id), [1, 2, 3])
            XCTAssertEqual(album.thumbnails.count, 3)
        } else {
            XCTFail("Expected album, got \(items[0])")
        }
    }

    func testTwoAlbumsInSequenceStayDistinct() {
        let messages = [
            makeMessage(id: 1, albumId: 100),
            makeMessage(id: 2, albumId: 100),
            makeMessage(id: 3, albumId: 200),
            makeMessage(id: 4, albumId: 200)
        ]

        let items = MessageAlbumInfo.group(messages)

        XCTAssertEqual(items.count, 2)
        guard case .album(let a1) = items[0], case .album(let a2) = items[1] else {
            return XCTFail("Expected two albums, got \(items)")
        }
        XCTAssertEqual(a1.albumId, 100)
        XCTAssertEqual(a1.messages.map(\.id), [1, 2])
        XCTAssertEqual(a2.albumId, 200)
        XCTAssertEqual(a2.messages.map(\.id), [3, 4])
    }

    func testStandaloneMessageBetweenAlbums() {
        let messages = [
            makeMessage(id: 1, albumId: 100),
            makeMessage(id: 2, albumId: 100),
            makeMessage(id: 3, albumId: 0, content: .text("hello")),
            makeMessage(id: 4, albumId: 200),
            makeMessage(id: 5, albumId: 200)
        ]

        let items = MessageAlbumInfo.group(messages)

        XCTAssertEqual(items.count, 3)
        guard case .album(let first) = items[0],
              case .message(let middle) = items[1],
              case .album(let last) = items[2] else {
            return XCTFail("Unexpected items: \(items)")
        }
        XCTAssertEqual(first.albumId, 100)
        XCTAssertEqual(middle.id, 3)
        XCTAssertEqual(last.albumId, 200)
    }

    func testDeletingMessagesUntilOneRemainsFallsBackToMessage() {
        // Simulate "user deleted everything but one photo from a 3-photo album".
        // The remaining message still carries mediaAlbumId, but group() keeps
        // it as a singleton because there is no sibling.
        let messages = [
            makeMessage(id: 2, albumId: 100)
        ]

        let items = MessageAlbumInfo.group(messages)

        XCTAssertEqual(items.count, 1)
        if case .message(let m) = items[0] {
            XCTAssertEqual(m.id, 2)
            XCTAssertEqual(m.mediaAlbumId, 100)
        } else {
            XCTFail("Expected singleton message, got \(items[0])")
        }
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(MessageAlbumInfo.group([]).isEmpty)
    }

    func testAlbumCaptionPicksFirstNonEmpty() {
        let messages = [
            makeMessage(id: 1, albumId: 100,
                        content: .photo(caption: "", fileId: "f1", width: 100, height: 100, minithumbnail: nil)),
            makeMessage(id: 2, albumId: 100,
                        content: .photo(caption: "look at this", fileId: "f2", width: 100, height: 100, minithumbnail: nil)),
            makeMessage(id: 3, albumId: 100,
                        content: .photo(caption: "", fileId: "f3", width: 100, height: 100, minithumbnail: nil))
        ]

        let items = MessageAlbumInfo.group(messages)
        guard case .album(let album) = items[0] else {
            return XCTFail("Expected album")
        }
        XCTAssertEqual(album.caption, "look at this")
    }

    /// The mosaic cells draw the preview size; the gallery opens the full one.
    func testAlbumThumbnailKeepsBothTheFullAndThePreviewFile() {
        let photo = makeMessage(id: 1, albumId: 100,
                                content: .photo(caption: "", fileId: "full", width: 1280, height: 960, minithumbnail: nil, previewFileId: "preview"))
        let plain = makeMessage(id: 2, albumId: 100,
                                content: .photo(caption: "", fileId: "only", width: 100, height: 100, minithumbnail: nil))

        let thumbnails = MessageAlbumInfo(albumId: 100, messages: [photo, plain]).thumbnails

        XCTAssertEqual(thumbnails.map(\.fileId), ["full", "only"])
        XCTAssertEqual(thumbnails.map(\.previewFileId), ["preview", nil])
        XCTAssertEqual(thumbnails.map(\.smallFileId), ["preview", "only"])
        XCTAssertEqual(thumbnails.map(\.bigFileId), ["full", "only"])
    }

    func testTimelineSectionsShowSeparatorOnFirstMessageAndDayChange() {
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
        let dayTwo = dayOne.addingTimeInterval(86_400)
        let messages = [
            makeMessage(id: 1, content: .text("one"), date: dayOne),
            makeMessage(id: 2, content: .text("two"), date: dayOne.addingTimeInterval(60)),
            makeMessage(id: 3, content: .text("three"), date: dayTwo)
        ]

        let sections = ChatTimelineSection.build(from: messages, calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(sections.map(\.showsDateSeparator), [true, false, true])
        XCTAssertEqual(sections.map(\.id), ["msg:1:1", "msg:1:2", "msg:1:3"])
    }

    func testTimelineSectionsKeepSingleSeparatorForAlbum() {
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = [
            makeMessage(id: 1, albumId: 100, date: dayOne),
            makeMessage(id: 2, albumId: 100, date: dayOne.addingTimeInterval(60)),
            makeMessage(id: 3, content: .text("after"), date: dayOne.addingTimeInterval(120))
        ]

        let sections = ChatTimelineSection.build(from: messages, calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.map(\.showsDateSeparator), [true, false])
        XCTAssertEqual(sections.map(\.id), ["album:100", "msg:1:3"])
    }

    func testReplyTargetForMessageUsesMessagePreview() {
        let message = makeMessage(
            id: 10,
            content: .text(FormattedString(text: "hello", entities: []))
        )

        let target = ComposeTarget.reply(to: message, chatId: 99)

        XCTAssertEqual(target.chatId, 99)
        XCTAssertEqual(target.replyToId, 10)
        XCTAssertEqual(target.replyToSenderName, "Sender")
        XCTAssertEqual(target.replyToPreview, "hello")
    }

    func testReplyTargetForAlbumUsesFirstMessageAndCaptionPreview() {
        let messages = [
            makeMessage(id: 1, albumId: 100,
                        content: .photo(caption: "", fileId: "f1", width: 100, height: 100, minithumbnail: nil)),
            makeMessage(id: 2, albumId: 100,
                        content: .photo(caption: "album caption", fileId: "f2", width: 100, height: 100, minithumbnail: nil))
        ]
        let album = MessageAlbumInfo(albumId: 100, messages: messages)

        let target = ComposeTarget.reply(to: album, chatId: 99)

        XCTAssertEqual(target?.chatId, 99)
        XCTAssertEqual(target?.replyToId, 1)
        XCTAssertEqual(target?.replyToSenderName, "Sender")
        XCTAssertEqual(target?.replyToPreview, "album caption")
    }

    func testChatListSectionsSplitPinnedAndRegularChatsWithoutReordering() {
        let chats = [
            ChatInfo(id: 1, title: "Regular 1", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 30),
            ChatInfo(id: 2, title: "Pinned 1", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 20, isPinned: true),
            ChatInfo(id: 3, title: "Regular 2", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 10),
            ChatInfo(id: 4, title: "Pinned 2", lastMessage: nil, unreadCount: 0, isGroup: false, isMuted: false, order: 5, isPinned: true)
        ]

        let sections = ChatListSections(chats: chats)

        XCTAssertEqual(sections.pinned.map(\.id), [2, 4])
        XCTAssertEqual(sections.regular.map(\.id), [1, 3])
        XCTAssertFalse(sections.isEmpty)
    }

    func testChatListSectionsEmptyInputProducesEmptySections() {
        let sections = ChatListSections(chats: [])

        XCTAssertTrue(sections.pinned.isEmpty)
        XCTAssertTrue(sections.regular.isEmpty)
        XCTAssertTrue(sections.isEmpty)
    }
}
