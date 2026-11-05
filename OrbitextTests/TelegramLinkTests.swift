import XCTest
@testable import OrbitextWatch

/// Classification of bot button URLs: in-app public chats, external web
/// links, Telegram-only links the watch cannot handle, and garbage.
final class TelegramLinkTests: XCTestCase {
    // MARK: - Public chats

    func testPlainTMeLinkIsPublicChat() {
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov"), .publicChat(username: "durov"))
    }

    func testTelegramMeAndTelegramDogHostsArePublicChats() {
        XCTAssertEqual(TelegramLink(string: "https://telegram.me/durov"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "https://telegram.dog/durov"), .publicChat(username: "durov"))
    }

    func testWwwPrefixAndHttpSchemeAreAccepted() {
        XCTAssertEqual(TelegramLink(string: "https://www.t.me/durov"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "http://t.me/durov"), .publicChat(username: "durov"))
    }

    func testMessageLinkOpensTheChat() {
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov/123"), .publicChat(username: "durov"))
    }

    func testQueryAndTrailingSlashDoNotChangeTheChat() {
        XCTAssertEqual(TelegramLink(string: "https://t.me/some_bot?start=payload"), .publicChat(username: "some_bot"))
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov/"), .publicChat(username: "durov"))
    }

    func testBareLinkWithoutSchemeIsAccepted() {
        XCTAssertEqual(TelegramLink(string: "t.me/durov"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "telegram.me/durov"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "www.t.me/durov"), .publicChat(username: "durov"))
    }

    func testHostCaseIsIgnoredButUsernameCaseIsKept() {
        XCTAssertEqual(TelegramLink(string: "HTTPS://T.ME/Durov"), .publicChat(username: "Durov"))
        XCTAssertEqual(TelegramLink(string: "T.me/Durov"), .publicChat(username: "Durov"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(TelegramLink(string: "  https://t.me/durov\n"), .publicChat(username: "durov"))
    }

    func testTgResolveLinkIsPublicChat() {
        XCTAssertEqual(TelegramLink(string: "tg://resolve?domain=durov"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "tg://resolve?domain=durov&post=5"), .publicChat(username: "durov"))
        XCTAssertEqual(TelegramLink(string: "TG://resolve?domain=durov"), .publicChat(username: "durov"))
    }

    // MARK: - Unsupported Telegram links

    func testReservedPathsAreUnsupported() {
        let links = [
            "https://t.me/joinchat/AAAAAEabc",
            "https://t.me/+AbCdEfGhIjK",
            "https://t.me/addstickers/CoolPack",
            "https://t.me/addemoji/Pack",
            "https://t.me/c/123/4",
            "https://t.me/s/durov",
            "https://t.me/proxy?server=1.2.3.4&port=443&secret=ab",
            "https://t.me/socks?server=1.2.3.4&port=1080",
            "https://t.me/share/url?url=https://example.com",
            "https://t.me/invoice/slug",
            "https://t.me/giftcode/abc",
            "https://t.me/setlanguage/en",
            "https://t.me/Joinchat/AAAAAEabc"
        ]

        for link in links {
            XCTAssertEqual(TelegramLink(string: link), .unsupported, link)
        }
    }

    func testBareReservedPathIsUnsupported() {
        XCTAssertEqual(TelegramLink(string: "t.me/joinchat/AAAAAEabc"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "t.me/addstickers/CoolPack"), .unsupported)
    }

    func testExtraPathComponentsAreUnsupported() {
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov/extra/path"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov/not_a_number"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "https://t.me/durov/12/34"), .unsupported)
    }

    func testTMeWithoutPathOrWithInvalidUsernameIsUnsupported() {
        XCTAssertEqual(TelegramLink(string: "https://t.me/"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "https://t.me"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "https://t.me/abc"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "https://t.me/1durov"), .unsupported)
    }

    func testOtherTgLinksAreUnsupported() {
        XCTAssertEqual(TelegramLink(string: "tg://other"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "tg://join?invite=abc"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "tg://resolve"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "tg://resolve?domain=ab"), .unsupported)
        XCTAssertEqual(TelegramLink(string: "tg://resolve?other=durov"), .unsupported)
    }

    // MARK: - External links

    func testOrdinaryWebLinkIsExternal() throws {
        let link = TelegramLink(string: "https://example.com/x")

        XCTAssertEqual(link, try .external(XCTUnwrap(URL(string: "https://example.com/x"))))
    }

    func testHttpLinkWithQueryIsExternalAndKeepsTheFullUrl() throws {
        let link = TelegramLink(string: "http://example.com/a/b?c=d#frag")

        XCTAssertEqual(link, try .external(XCTUnwrap(URL(string: "http://example.com/a/b?c=d#frag"))))
    }

    func testLookalikeHostsAreExternalNotTelegram() throws {
        let lookalikes = ["https://t.me.evil.com/durov", "https://nott.me/durov", "https://evil.com/t.me/durov"]

        for link in lookalikes {
            XCTAssertEqual(TelegramLink(string: link), try .external(XCTUnwrap(URL(string: link))), link)
        }
    }

    func testMailtoAndTelLinksAreExternal() throws {
        XCTAssertEqual(
            TelegramLink(string: "mailto:bot@example.com"),
            try .external(XCTUnwrap(URL(string: "mailto:bot@example.com")))
        )
        XCTAssertEqual(
            TelegramLink(string: "tel:+15551234567"),
            try .external(XCTUnwrap(URL(string: "tel:+15551234567")))
        )
    }

    // MARK: - Garbage

    func testEmptyAndWhitespaceStringsAreNil() {
        XCTAssertNil(TelegramLink(string: ""))
        XCTAssertNil(TelegramLink(string: "   "))
        XCTAssertNil(TelegramLink(string: "\n\t"))
    }

    func testStringsWithoutSchemeAreNil() {
        XCTAssertNil(TelegramLink(string: "hello"))
        XCTAssertNil(TelegramLink(string: "just some words"))
        XCTAssertNil(TelegramLink(string: "t.me"))
        XCTAssertNil(TelegramLink(string: "example.com/page"))
    }

    func testSchemeLinksWithoutHostAreNil() {
        XCTAssertNil(TelegramLink(string: "javascript:alert(1)"))
        XCTAssertNil(TelegramLink(string: "file:///etc/passwd"))
    }

    // MARK: - isUsername

    func testIsUsernameAcceptsValidNames() {
        XCTAssertTrue(TelegramLink.isUsername("abcd"))
        XCTAssertTrue(TelegramLink.isUsername("Durov"))
        XCTAssertTrue(TelegramLink.isUsername("some_bot"))
        XCTAssertTrue(TelegramLink.isUsername("a1b2c3"))
        XCTAssertTrue(TelegramLink.isUsername(String(repeating: "a", count: 32)))
    }

    func testIsUsernameRejectsWrongLength() {
        XCTAssertFalse(TelegramLink.isUsername(""))
        XCTAssertFalse(TelegramLink.isUsername("abc"))
        XCTAssertFalse(TelegramLink.isUsername(String(repeating: "a", count: 33)))
    }

    func testIsUsernameRejectsLeadingDigitOrUnderscore() {
        XCTAssertFalse(TelegramLink.isUsername("1abcd"))
        XCTAssertFalse(TelegramLink.isUsername("_abcd"))
        XCTAssertFalse(TelegramLink.isUsername("+abcd"))
    }

    func testIsUsernameRejectsNonAsciiCharacters() {
        XCTAssertFalse(TelegramLink.isUsername("\u{0434}\u{0443}\u{0440}\u{043E}\u{0432}"))
        XCTAssertFalse(TelegramLink.isUsername("abcd\u{00E9}"))
        XCTAssertFalse(TelegramLink.isUsername("\u{00E9}abcd"))
    }

    func testIsUsernameRejectsSeparatorsAndSpaces() {
        XCTAssertFalse(TelegramLink.isUsername("ab-cd"))
        XCTAssertFalse(TelegramLink.isUsername("ab cd"))
        XCTAssertFalse(TelegramLink.isUsername("ab.cd"))
        XCTAssertFalse(TelegramLink.isUsername("ab@cd"))
    }

    func testIsUsernameAllowsUnderscoreInsideAndAtTheEnd() {
        XCTAssertTrue(TelegramLink.isUsername("ab_cd"))
        XCTAssertTrue(TelegramLink.isUsername("abc_d"))
        XCTAssertTrue(TelegramLink.isUsername("abcd_"))
    }
}
