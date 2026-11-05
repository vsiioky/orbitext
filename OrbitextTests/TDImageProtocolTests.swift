import XCTest
@testable import OrbitextWatch

final class TDImageProtocolTests: XCTestCase {
    private var service: TDLibService!

    override func setUp() {
        super.setUp()
        service = TDLibService()
    }

    // MARK: - Parser: minithumbnail.data as Data

    func testParsePhotoMinithumbnailFromData() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": [
                "minithumbnail": [
                    "@type": "minithumbnail",
                    "width": 40,
                    "height": 30,
                    "data": bytes
                ] as [String: Any],
                "sizes": [
                    ["photo": ["id": 1] as [String: Any], "width": 320, "height": 240] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .photo(_, _, _, _, let mini, _) = parsed else {
            return XCTFail("Expected .photo, got \(parsed)")
        }
        XCTAssertEqual(mini, bytes)
    }

    func testParsePhotoMinithumbnailFromBase64String() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let base64 = bytes.base64EncodedString()
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": [
                "minithumbnail": [
                    "@type": "minithumbnail",
                    "data": base64
                ] as [String: Any],
                "sizes": [
                    ["photo": ["id": 2] as [String: Any], "width": 100, "height": 100] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .photo(_, _, _, _, let mini, _) = parsed else {
            return XCTFail("Expected .photo, got \(parsed)")
        }
        XCTAssertEqual(mini, bytes)
    }

    func testParseVideoMinithumbnailFromData() {
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let content: [String: Any] = [
            "@type": "messageVideo",
            "caption": ["text": ""] as [String: Any],
            "video": [
                "duration": 5,
                "width": 100,
                "height": 100,
                "video": ["id": 10] as [String: Any],
                "minithumbnail": [
                    "data": bytes
                ] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .video(_, _, _, _, _, _, let mini) = parsed else {
            return XCTFail("Expected .video, got \(parsed)")
        }
        XCTAssertEqual(mini, bytes)
    }

    func testParseVideoNoteMinithumbnailFromBase64() {
        let bytes = Data([0x10, 0x20, 0x30])
        let content: [String: Any] = [
            "@type": "messageVideoNote",
            "video_note": [
                "duration": 3,
                "video": ["id": 11] as [String: Any],
                "minithumbnail": [
                    "data": bytes.base64EncodedString()
                ] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .videoNote(_, _, _, let mini) = parsed else {
            return XCTFail("Expected .videoNote, got \(parsed)")
        }
        XCTAssertEqual(mini, bytes)
    }

    func testParseAnimationMinithumbnail() {
        let bytes = Data([0x42, 0x42])
        let content: [String: Any] = [
            "@type": "messageAnimation",
            "animation": [
                "animation": ["id": 77] as [String: Any],
                "minithumbnail": ["data": bytes] as [String: Any]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .animation(_, let mini) = parsed else {
            return XCTFail("Expected .animation, got \(parsed)")
        }
        XCTAssertEqual(mini, bytes)
    }

    func testParseMissingMinithumbnailIsNil() {
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": [
                "sizes": [
                    ["photo": ["id": 1] as [String: Any], "width": 100, "height": 100] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .photo(_, _, _, _, let mini, _) = parsed else {
            return XCTFail("Expected .photo")
        }
        XCTAssertNil(mini)
    }

    func testParseMalformedBase64IsNil() {
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": [
                "minithumbnail": ["data": "!!!not-base64!!!"] as [String: Any],
                "sizes": [
                    ["photo": ["id": 1] as [String: Any], "width": 100, "height": 100] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .photo(_, _, _, _, let mini, _) = parsed else {
            return XCTFail("Expected .photo")
        }
        XCTAssertNil(mini)
    }

    // MARK: - NSDictionary bridging (avoid the trap from MEMORY)

    func testParseMinithumbnailThroughNSDictionary() {
        let bytes = Data([0x99, 0x88])
        let inner: NSDictionary = ["data": bytes]
        let nested: NSDictionary = [
            "minithumbnail": inner,
            "sizes": [
                ["photo": ["id": 1] as [String: Any], "width": 50, "height": 50] as [String: Any]
            ]
        ]
        let content: [String: Any] = [
            "@type": "messagePhoto",
            "caption": ["text": ""] as [String: Any],
            "photo": nested
        ]
        let parsed = MessageContent.parsed(content)
        guard case .photo(_, _, _, _, let mini, _) = parsed else {
            return XCTFail("Expected .photo")
        }
        XCTAssertEqual(mini, bytes)
    }

    // MARK: - TDImageSource conformance

    func testMessageContentTDImageSourcePhoto() {
        let bytes = Data([1, 2])
        let content: MessageContent = .photo(caption: "", fileId: "abc", width: 1, height: 1, minithumbnail: bytes)
        XCTAssertEqual(content.minithumbnail, bytes)
        XCTAssertEqual(content.smallFileId, "abc")
        XCTAssertEqual(content.bigFileId, "abc")
    }

    func testMessageContentTDImageSourcePhotoPrefersThePreviewForSmall() {
        let content: MessageContent = .photo(caption: "", fileId: "big", width: 1, height: 1, minithumbnail: nil, previewFileId: "small")

        XCTAssertEqual(content.smallFileId, "small")
        XCTAssertEqual(content.bigFileId, "big")
    }

    func testMessageContentTDImageSourceVideoPrefersThumbnailForSmall() {
        let content: MessageContent = .video(
            caption: "", fileId: "video1", thumbnailId: "thumb1",
            width: 1, height: 1, duration: 1, minithumbnail: nil
        )
        XCTAssertEqual(content.smallFileId, "thumb1")
        XCTAssertEqual(content.bigFileId, "video1")
    }

    func testMessageContentTDImageSourceTextReturnsNil() {
        let content: MessageContent = .text("hello")
        XCTAssertNil(content.minithumbnail)
        XCTAssertNil(content.smallFileId)
        XCTAssertNil(content.bigFileId)
    }

    // MARK: - AlbumThumbnail rebuild

    func testAlbumThumbnailPropagatesMinithumbnailFromPhoto() {
        let bytes = Data([0xAB])
        let message = MessageInfo(
            id: 1, chatId: 1, senderName: "S", senderId: 1,
            content: .photo(caption: "", fileId: "f1", width: 10, height: 20, minithumbnail: bytes),
            date: Date(), isOutgoing: false, isRead: false
        )
        let thumb = AlbumThumbnail(message: message)
        XCTAssertNotNil(thumb)
        XCTAssertEqual(thumb?.minithumbnail, bytes)
        XCTAssertEqual(thumb?.fileId, "f1")
    }

    func testAlbumThumbnailPropagatesMinithumbnailFromVideo() {
        let bytes = Data([0xCD])
        let message = MessageInfo(
            id: 2, chatId: 1, senderName: "S", senderId: 1,
            content: .video(caption: "", fileId: "v", thumbnailId: "t", width: 10, height: 10, duration: 1, minithumbnail: bytes),
            date: Date(), isOutgoing: false, isRead: false
        )
        let thumb = AlbumThumbnail(message: message)
        XCTAssertEqual(thumb?.minithumbnail, bytes)
        XCTAssertEqual(thumb?.fileId, "t")
    }

    func testAlbumThumbnailNilForNonMedia() {
        let message = MessageInfo(
            id: 3, chatId: 1, senderName: "S", senderId: 1,
            content: .text("hi"),
            date: Date(), isOutgoing: false, isRead: false
        )
        XCTAssertNil(AlbumThumbnail(message: message))
    }
}
