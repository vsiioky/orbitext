import SwiftUI
import XCTest
@testable import OrbitextWatch

final class FormattedStringParserTests: XCTestCase {
    private func parse(_ raw: [String: Any]) -> FormattedString {
        FormattedString(tdApi: TDApi.decodeFormattedText(raw))
    }

    // MARK: - FormattedString(tdApi:)

    func testParseFormattedTextHandlesPlainPayload() {
        let raw: [String: Any] = ["text": "hello", "entities": []]
        let parsed = parse(raw)
        XCTAssertEqual(parsed.text, "hello")
        XCTAssertTrue(parsed.entities.isEmpty)
    }

    func testMessageTextWithoutATextIsEmpty() {
        let content = MessageContent(tdApi: TDApi.decodeMessageContent(["@type": "messageText"]))

        XCTAssertEqual(content, .text(FormattedString.empty))
    }

    // MARK: - TextEntity(tdApi:) per kind

    private func entity(_ kind: String, offset: Int, length: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var type: [String: Any] = ["@type": kind]
        type.merge(extra) { _, new in new }
        return ["offset": offset, "length": length, "type": type as [String: Any]]
    }

    func testParseAllSupportedEntityKinds() {
        let raw: [String: Any] = [
            "text": "abcdefghij",
            "entities": [
                entity("textEntityTypeBold", offset: 0, length: 1),
                entity("textEntityTypeItalic", offset: 1, length: 1),
                entity("textEntityTypeCode", offset: 2, length: 1),
                entity("textEntityTypePre", offset: 3, length: 1),
                entity("textEntityTypePreCode", offset: 4, length: 1, extra: ["language": "swift"]),
                entity("textEntityTypeUnderline", offset: 5, length: 1),
                entity("textEntityTypeStrikethrough", offset: 6, length: 1),
                entity("textEntityTypeSpoiler", offset: 7, length: 1),
                entity("textEntityTypeBlockQuote", offset: 8, length: 1),
                entity("textEntityTypeExpandableBlockQuote", offset: 9, length: 1)
            ]
        ]
        let parsed = parse(raw)
        XCTAssertEqual(parsed.entities.count, 10)

        guard case .preCode(_, _, let lang) = parsed.entities[4] else {
            return XCTFail("expected preCode")
        }
        XCTAssertEqual(lang, "swift")

        guard case .blockQuote = parsed.entities[9] else {
            return XCTFail("expandable blockquote should collapse to .blockQuote")
        }
    }

    func testParseEntityWithTypedPayloads() {
        let raw: [String: Any] = [
            "text": "click here for @alex and reply",
            "entities": [
                entity("textEntityTypeTextUrl", offset: 0, length: 5, extra: ["url": "https://orbitext.app"]),
                entity("textEntityTypeMention", offset: 15, length: 5),
                entity("textEntityTypeMentionName", offset: 15, length: 5, extra: ["user_id": 12345]),
                entity("textEntityTypeCustomEmoji", offset: 0, length: 5, extra: ["custom_emoji_id": "987654321"])
            ]
        ]
        let parsed = parse(raw)
        XCTAssertEqual(parsed.entities.count, 4)

        guard case .textUrl(_, _, let href) = parsed.entities[0] else {
            return XCTFail("expected textUrl")
        }
        XCTAssertEqual(href, "https://orbitext.app")

        guard case .mentionName(_, _, let userId) = parsed.entities[2] else {
            return XCTFail("expected mentionName")
        }
        XCTAssertEqual(userId, 12345)

        guard case .customEmoji(_, _, let emojiId) = parsed.entities[3] else {
            return XCTFail("expected customEmoji")
        }
        XCTAssertEqual(emojiId, 987654321)
    }

    func testParseUnknownEntityKindIsDropped() {
        let raw: [String: Any] = [
            "text": "x",
            "entities": [entity("textEntityTypeFuturisticBananaSplit", offset: 0, length: 1)]
        ]
        XCTAssertTrue(parse(raw).entities.isEmpty)
    }

    func testParseZeroLengthEntityIsDropped() {
        let raw: [String: Any] = [
            "text": "abc",
            "entities": [entity("textEntityTypeBold", offset: 0, length: 0)]
        ]
        XCTAssertTrue(parse(raw).entities.isEmpty)
    }

    // MARK: - UTF-16 offset preservation with non-BMP characters

    func testUTF16OffsetsSurviveEmojiInText() {
        // "🔥hello" - 🔥 occupies UTF-16 indices 0..1 (surrogate pair),
        // so "hello" begins at offset 2 and has length 5.
        let raw: [String: Any] = [
            "text": "🔥hello",
            "entities": [entity("textEntityTypeBold", offset: 2, length: 5)]
        ]
        let parsed = parse(raw)
        XCTAssertEqual(parsed.text, "🔥hello")

        let attr = parsed.attributedString
        let plain = String(attr.characters)
        XCTAssertEqual(plain, "🔥hello")

        // Find the bold run and verify it covers the trailing 5 ASCII chars.
        var boldText = ""
        for run in attr.runs {
            if run.font != nil {
                boldText += String(attr.characters[run.range])
            }
        }
        XCTAssertEqual(boldText, "hello")
    }

    func testOutOfRangeEntityDoesNotCrashAttributedString() {
        let raw: [String: Any] = [
            "text": "ab",
            "entities": [entity("textEntityTypeBold", offset: 5, length: 10)]
        ]
        let parsed = parse(raw)
        XCTAssertEqual(parsed.entities.count, 1) // parser keeps it
        let attr = parsed.attributedString
        XCTAssertEqual(String(attr.characters), "ab")
    }

    // MARK: - Attributes of each entity

    func testEachEntityGetsItsFontLineColorOrLink() throws {
        let text = "bold italic code under strike quote @alice Alice x.org site t@x.org +7 9 #tag"
        func span(_ part: String) -> (offset: Int, length: Int) {
            let range = text.range(of: part)!
            return (text.utf16.distance(from: text.startIndex, to: range.lowerBound), part.utf16.count)
        }
        func at(_ part: String, _ make: (Int, Int) -> TextEntity) -> TextEntity {
            let span = span(part)
            return make(span.offset, span.length)
        }
        let formatted = FormattedString(text: text, entities: [
            at("bold") { .bold(offset: $0, length: $1) },
            at("italic") { .italic(offset: $0, length: $1) },
            at("code") { .code(offset: $0, length: $1) },
            at("under") { .underline(offset: $0, length: $1) },
            at("strike") { .strikethrough(offset: $0, length: $1) },
            at("quote") { .blockQuote(offset: $0, length: $1) },
            at("@alice") { .mention(offset: $0, length: $1) },
            at("Alice") { .mentionName(offset: $0, length: $1, userId: 5) },
            at("x.org") { .url(offset: $0, length: $1) },
            at("site") { .textUrl(offset: $0, length: $1, href: "https://example.com/a") },
            at("t@x.org") { .email(offset: $0, length: $1) },
            at("+7 9") { .phone(offset: $0, length: $1) },
            at("#tag") { .hashtag(offset: $0, length: $1) }
        ])

        let attr = formatted.attributedString
        func run(_ part: String) throws -> AttributedSubstring {
            try attr[XCTUnwrap(attr.range(of: part))]
        }

        XCTAssertEqual(try run("bold").font, .body.bold())
        XCTAssertEqual(try run("italic").font, .body.italic())
        XCTAssertEqual(try run("code").font, .body.monospaced())
        XCTAssertEqual(try run("code").backgroundColor, .gray.opacity(0.18))
        XCTAssertEqual(try run("under").underlineStyle, .single)
        XCTAssertEqual(try run("strike").strikethroughStyle, .single)
        XCTAssertEqual(try run("quote").backgroundColor, .gray.opacity(0.2))
        XCTAssertEqual(try run("@alice").foregroundColor, .accentColor)
        XCTAssertEqual(try run("@alice").link, URL(string: "https://t.me/alice"))
        XCTAssertEqual(try run("Alice").link, URL(string: "tg://user?id=5"))
        XCTAssertEqual(try run("x.org").link, URL(string: "https://x.org"))
        XCTAssertEqual(try run("site").link, URL(string: "https://example.com/a"))
        XCTAssertEqual(try run("t@x.org").link, URL(string: "mailto:t@x.org"))
        XCTAssertEqual(try run("+7 9").link, URL(string: "tel://+79"))
        XCTAssertEqual(try run("#tag").foregroundColor, .accentColor)
        XCTAssertNil(try run("#tag").link)
        XCTAssertNil(try run("bold").link)
        XCTAssertNil(try run("bold").foregroundColor)
    }

    // MARK: - FormattedString shape

    func testStringLiteralBuildsEmptyEntities() {
        let f: FormattedString = "hello"
        XCTAssertEqual(f.text, "hello")
        XCTAssertTrue(f.entities.isEmpty)
        XCTAssertFalse(f.isEmpty)
    }

    func testHasSpoilerReflectsEntityList() {
        var f = FormattedString(text: "secret", entities: [])
        XCTAssertFalse(f.hasSpoiler)
        f = FormattedString(text: "secret", entities: [.spoiler(offset: 0, length: 6)])
        XCTAssertTrue(f.hasSpoiler)
    }

    // MARK: - Spoilers in previews

    func testTextPreviewHidesSpoilerContent() {
        let secret = FormattedString(text: "Code: 1234, bring it", entities: [.spoiler(offset: 6, length: 4)])

        let preview = MessageContent.text(secret).textPreview

        XCTAssertFalse(preview.contains("1234"),
                       "Chat list, search, widget and notifications reveal the spoiler")
        XCTAssertTrue(preview.hasPrefix("Code: "))
        XCTAssertTrue(preview.hasSuffix(", bring it"))
    }

    func testCaptionPreviewHidesSpoilerContent() {
        let caption = FormattedString(text: "Look 1234", entities: [.spoiler(offset: 5, length: 4)])

        let preview = MessageContent.photo(caption: caption, fileId: "1", width: 1, height: 1, minithumbnail: nil)
            .textPreview

        XCTAssertFalse(preview.contains("1234"))
        XCTAssertTrue(preview.hasPrefix("Look "))
    }

    func testMaskingSpoilersKeepsOtherEntityOffsets() {
        let source = FormattedString(text: "Code: 1234, bold", entities: [
            .spoiler(offset: 6, length: 4),
            .bold(offset: 12, length: 4)
        ])

        let masked = source.maskingSpoilers

        XCTAssertEqual(masked.text, "Code: ▒▒▒▒, bold")
        XCTAssertEqual(masked.entities, [.bold(offset: 12, length: 4)])
        XCTAssertFalse(masked.hasSpoiler)
    }

    func testMaskingSpoilersDropsLinksInsideSpoiler() {
        let source = FormattedString(text: "see secret", entities: [
            .bold(offset: 0, length: 3),
            .spoiler(offset: 4, length: 6),
            .textUrl(offset: 4, length: 6, href: "https://secret.example")
        ])

        XCTAssertEqual(source.maskingSpoilers.entities, [.bold(offset: 0, length: 3)],
                       "A masked link stays tappable and opens what the spoiler hides")
    }

    func testRevealedPreviewKeepsSpoilerTextForVoiceOver() {
        let content = MessageContent.text(FormattedString(text: "Code 1234", entities: [.spoiler(offset: 5, length: 4)]))

        XCTAssertTrue(content.hasSpoiler)
        XCTAssertEqual(content.revealedTextPreview, "Code 1234")
        XCTAssertFalse(MessageContent.text("plain").hasSpoiler)
    }

    func testMaskingSpoilersCoversEmojiByUTF16Units() {
        let source = FormattedString(text: "a😀b", entities: [.spoiler(offset: 1, length: 2)])

        XCTAssertEqual(source.maskingSpoilers.text, "a▒▒b")
    }

    func testSpokenPreviewNamesEachSpoilerOnce() {
        let source = FormattedString(text: "Code 1234 and 99", entities: [
            .spoiler(offset: 5, length: 4),
            .spoiler(offset: 14, length: 2)
        ])
        let name = L10n.string("Spoiler")

        let spoken = MessageContent.text(source).textPreview.speakingSpoilerMasks

        XCTAssertEqual(spoken, "Code \(name) and \(name)")
        XCTAssertEqual("No spoilers here".speakingSpoilerMasks, "No spoilers here")
    }

    func testCodableRoundTrip() throws {
        let original = FormattedString(text: "bold and italic", entities: [
            .bold(offset: 0, length: 4),
            .italic(offset: 9, length: 6)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FormattedString.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - TimeFormatting

    func testClockDurationFormatsFloodWaitIntervals() {
        XCTAssertEqual(TimeFormatting.clockDuration(59), "0:59")
        XCTAssertEqual(TimeFormatting.clockDuration(125), "2:05")
        XCTAssertEqual(TimeFormatting.clockDuration(3_725), "1:02:05")
    }
}
