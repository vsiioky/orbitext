import XCTest
@testable import OrbitextWatch

/// Sponsored messages in channels (Telegram API Terms of Service 3.3): what
/// the transport asks TDLib for and how it reads the answers, through the
/// scripted TDLib client, and when the chat screen's store asks at all.
final class SponsoredMessageTransportTests: XCTestCase {
    func testChannelAdsAreReadFromGetChatSponsoredMessages() async throws {
        let fixture = ScriptedServiceFixture { request in
            guard request["@type"] as? String == "getChatSponsoredMessages" else { return .result(["@type": "ok"]) }
            return .result([
                "@type": "sponsoredMessages",
                "messages": [Self.textAd(id: 7, isRecommended: false)],
                "messages_between": 0
            ])
        }
        defer { fixture.finish() }

        let batch = try await fixture.service.getChatSponsoredMessages(chatId: -100)

        XCTAssertEqual(fixture.transport.requests(ofType: "getChatSponsoredMessages").first?["chat_id"] as? Int, -100)
        XCTAssertEqual(batch.messagesBetween, 0)
        let ad = try XCTUnwrap(batch.messages.first)
        XCTAssertEqual(ad.chatId, -100)
        XCTAssertEqual(ad.messageId, 7)
        XCTAssertEqual(ad.title, "Sponsor title")
        XCTAssertEqual(ad.text.text, "Buy watches")
        XCTAssertEqual(ad.buttonText, "Open channel")
        XCTAssertEqual(ad.url, "https://t.me/sponsor")
        XCTAssertEqual(ad.sponsorInfo, "Sponsor Inc.")
        XCTAssertEqual(ad.additionalInfo, "Ad #1")
        XCTAssertTrue(ad.canBeReported)
        XCTAssertFalse(ad.isRecommended)
    }

    func testMediaAdShowsItsCaption() async throws {
        let fixture = ScriptedServiceFixture { _ in
            .result([
                "@type": "sponsoredMessages",
                "messages": [[
                    "@type": "sponsoredMessage", "message_id": 8, "is_recommended": true, "can_be_reported": false,
                    "content": [
                        "@type": "messagePhoto",
                        "caption": ["@type": "formattedText", "text": "Look at this"] as [String: Any]
                    ] as [String: Any],
                    "sponsor": ["@type": "advertisementSponsor", "url": "https://example.com", "info": ""] as [String: Any],
                    "title": "Recommended channel", "button_text": "View", "additional_info": ""
                ] as [String: Any]],
                "messages_between": 5
            ])
        }
        defer { fixture.finish() }

        let batch = try await fixture.service.getChatSponsoredMessages(chatId: -100)

        XCTAssertEqual(batch.messagesBetween, 5)
        XCTAssertEqual(batch.messages.first?.text.text, "Look at this")
        XCTAssertEqual(batch.messages.first?.isRecommended, true)
    }

    func testAdWithNothingToShowIsDropped() async throws {
        let fixture = ScriptedServiceFixture { _ in
            .result([
                "@type": "sponsoredMessages",
                "messages": [["@type": "sponsoredMessage", "message_id": 9] as [String: Any]],
                "messages_between": 0
            ])
        }
        defer { fixture.finish() }

        let batch = try await fixture.service.getChatSponsoredMessages(chatId: -100)

        XCTAssertTrue(batch.messages.isEmpty)
    }

    func testFailedRequestIsThrown() async {
        let fixture = ScriptedServiceFixture { _ in .error(code: 400, message: "CHAT_INVALID") }
        defer { fixture.finish() }

        do {
            _ = try await fixture.service.getChatSponsoredMessages(chatId: -100)
            XCTFail("expected an error")
        } catch {}
    }

    func testViewIsReportedThroughViewMessagesWithoutForcingARead() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        try await fixture.service.viewSponsoredMessage(chatId: -100, messageId: 7)

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "viewMessages").first)
        XCTAssertEqual(request["chat_id"] as? Int, -100)
        XCTAssertEqual(request["message_ids"] as? [Int], [7])
        XCTAssertEqual(request["force_read"] as? Bool, false)
    }

    func testClickIsReportedWithClickChatSponsoredMessage() async throws {
        let fixture = ScriptedServiceFixture()
        defer { fixture.finish() }

        try await fixture.service.clickSponsoredMessage(chatId: -100, messageId: 7)

        let request = try XCTUnwrap(fixture.transport.requests(ofType: "clickChatSponsoredMessage").first)
        XCTAssertEqual(request["chat_id"] as? Int, -100)
        XCTAssertEqual(request["message_id"] as? Int, 7)
        XCTAssertEqual(request["is_media_click"] as? Bool, false)
        XCTAssertEqual(request["from_fullscreen"] as? Bool, false)
    }

    func testReportAsksForAnOptionAndSendsTheChosenOne() async throws {
        let optionId = Data([1, 2, 3])
        let fixture = ScriptedServiceFixture { request in
            if (request["option_id"] as? String ?? "").isEmpty {
                return .result([
                    "@type": "reportSponsoredResultOptionRequired",
                    "title": "Why?",
                    "options": [["@type": "reportOption", "id": optionId.base64EncodedString(), "text": "Spam"] as [String: Any]]
                ])
            }
            return .result(["@type": "reportSponsoredResultOk"])
        }
        defer { fixture.finish() }

        let first = try await fixture.service.reportSponsoredMessage(chatId: -100, messageId: 7, optionId: Data())
        guard case .optionRequired(let title, let options) = first else { return XCTFail("expected options, got \(first)") }
        XCTAssertEqual(title, "Why?")
        XCTAssertEqual(options, [SponsoredReportOption(id: optionId, text: "Spam")])

        let second = try await fixture.service.reportSponsoredMessage(chatId: -100, messageId: 7, optionId: optionId)

        XCTAssertEqual(second, .reported)
        let requests = fixture.transport.requests(ofType: "reportChatSponsoredMessage")
        XCTAssertEqual(requests.map { $0["option_id"] as? String }, ["", optionId.base64EncodedString()])
        XCTAssertEqual(requests.first?["message_id"] as? Int, 7)
    }

    func testReportResultsMapToTheirOutcome() async throws {
        let expected: [(String, SponsoredReportResult)] = [
            ("reportSponsoredResultOk", .reported),
            ("reportSponsoredResultFailed", .failed),
            ("reportSponsoredResultAdsHidden", .adsHidden),
            ("reportSponsoredResultPremiumRequired", .premiumRequired)
        ]
        for (type, outcome) in expected {
            let fixture = ScriptedServiceFixture { _ in .result(["@type": type]) }
            let result = try await fixture.service.reportSponsoredMessage(chatId: -100, messageId: 7, optionId: Data())
            fixture.finish()
            XCTAssertEqual(result, outcome, type)
        }
    }

    static func textAd(id: Int, isRecommended: Bool) -> [String: Any] {
        [
            "@type": "sponsoredMessage",
            "message_id": id,
            "is_recommended": isRecommended,
            "can_be_reported": true,
            "content": [
                "@type": "messageText",
                "text": ["@type": "formattedText", "text": "Buy watches"] as [String: Any]
            ] as [String: Any],
            "sponsor": [
                "@type": "advertisementSponsor", "url": "https://t.me/sponsor", "info": "Sponsor Inc."
            ] as [String: Any],
            "title": "Sponsor title",
            "button_text": "Open channel",
            "accent_color_id": 1,
            "background_custom_emoji_id": 0,
            "additional_info": "Ad #1"
        ]
    }
}

/// When the chat screen's store asks for ads, and what it does with them.
@MainActor
final class SponsoredMessageStoreTests: XCTestCase {
    func testOnlyAChannelAsksForAds() async {
        let service = MockTelegramService()
        service.sponsoredBatches[-100] = SponsoredMessageBatch(messages: [Self.ad(chatId: -100)], messagesBetween: 0)
        let store = SponsoredMessageStore(service: service)

        await store.load(chatId: 5, isChannel: false)
        await store.load(chatId: -100, isChannel: true)

        XCTAssertEqual(service.sponsoredRequests, [-100])
        XCTAssertNil(store.message(for: 5))
        XCTAssertEqual(store.message(for: -100)?.messageId, 7)
    }

    func testFailedLoadShowsNoAd() async {
        let service = MockTelegramService()
        service.sponsoredError = TelegramServiceError.notStarted
        let store = SponsoredMessageStore(service: service)

        await store.load(chatId: -100, isChannel: true)

        XCTAssertNil(store.message(for: -100))
    }

    func testCancelledLoadKeepsTheAdShown() async {
        let service = MockTelegramService()
        service.sponsoredBatches[-100] = SponsoredMessageBatch(messages: [Self.ad(chatId: -100)], messagesBetween: 0)
        let store = SponsoredMessageStore(service: service)
        await store.load(chatId: -100, isChannel: true)

        service.sponsoredError = CancellationError()
        await store.load(chatId: -100, isChannel: true)

        XCTAssertNotNil(store.message(for: -100))
    }

    func testViewIsReportedOncePerAd() async {
        let service = MockTelegramService()
        let store = SponsoredMessageStore(service: service)
        let ad = Self.ad(chatId: -100)

        await store.markViewed(ad)
        await store.markViewed(ad)

        XCTAssertEqual(service.viewedSponsored.map(\.messageId), [7])
    }

    func testClickIsReportedAndOpensTheSponsorLink() async {
        let service = MockTelegramService()
        let store = SponsoredMessageStore(service: service)

        let url = await store.click(Self.ad(chatId: -100))

        XCTAssertEqual(service.clickedSponsored.map(\.messageId), [7])
        XCTAssertEqual(url, URL(string: "https://t.me/sponsor"))
    }

    func testReportedAdLeavesTheChat() async {
        let service = MockTelegramService()
        service.sponsoredBatches[-100] = SponsoredMessageBatch(messages: [Self.ad(chatId: -100)], messagesBetween: 0)
        service.sponsoredReportResult = .reported
        let store = SponsoredMessageStore(service: service)
        await store.load(chatId: -100, isChannel: true)

        let result = await store.report(Self.ad(chatId: -100), optionId: Data())

        XCTAssertEqual(result, .reported)
        XCTAssertNil(store.message(for: -100))
    }

    func testReportThatNeedsAnOptionKeepsTheAd() async {
        let service = MockTelegramService()
        service.sponsoredBatches[-100] = SponsoredMessageBatch(messages: [Self.ad(chatId: -100)], messagesBetween: 0)
        service.sponsoredReportResult = .optionRequired(title: "Why?", options: [])
        let store = SponsoredMessageStore(service: service)
        await store.load(chatId: -100, isChannel: true)

        _ = await store.report(Self.ad(chatId: -100), optionId: Data())

        XCTAssertNotNil(store.message(for: -100))
    }

    func testLabelSaysSponsoredOrRecommended() {
        XCTAssertEqual(Self.ad(chatId: 1).label, L10n.string("Sponsored"))
        XCTAssertEqual(Self.ad(chatId: 1, isRecommended: true).label, L10n.string("Recommended"))
    }

    static func ad(chatId: Int64, isRecommended: Bool = false) -> SponsoredMessage {
        SponsoredMessage(
            chatId: chatId, messageId: 7, isRecommended: isRecommended, canBeReported: true,
            title: "Sponsor", text: FormattedString(text: "Buy"), buttonText: "Open",
            url: "https://t.me/sponsor", sponsorInfo: "", additionalInfo: ""
        )
    }
}
