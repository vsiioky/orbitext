import Foundation

// MARK: - Sponsored messages from typed TDApi values

extension SponsoredMessage {
    /// Nil for an ad with neither a title nor text: nothing to show.
    init?(tdApi ad: TDApi.SponsoredMessage, chatId: Int64) {
        let text = Self.text(of: ad.content)
        guard ad.messageId != 0, !(ad.title.isEmpty && text.isEmpty) else { return nil }
        self.init(
            chatId: chatId,
            messageId: ad.messageId,
            isRecommended: ad.isRecommended,
            canBeReported: ad.canBeReported,
            title: ad.title,
            text: text,
            buttonText: ad.buttonText,
            url: ad.sponsor?.url ?? "",
            sponsorInfo: ad.sponsor?.info ?? "",
            additionalInfo: ad.additionalInfo
        )
    }

    /// An ad is text, or media with a caption (td_api.tl lists text,
    /// animation, photo and video); the watch shows the text either way.
    private static func text(of content: TDApi.MessageContent?) -> FormattedString {
        let formatted: TDApi.FormattedText?
        switch content {
        case .messageText(let m)?: formatted = m.text
        case .messagePhoto(let m)?: formatted = m.caption
        case .messageVideo(let m)?: formatted = m.caption
        case .messageAnimation(let m)?: formatted = m.caption
        default: formatted = nil
        }
        return formatted.map(FormattedString.init(tdApi:)) ?? .empty
    }
}

extension SponsoredMessageBatch {
    init(tdApi batch: TDApi.SponsoredMessages, chatId: Int64) {
        self.init(
            messages: batch.messages.compactMap { SponsoredMessage(tdApi: $0, chatId: chatId) },
            messagesBetween: Int(batch.messagesBetween)
        )
    }
}

extension SponsoredReportResult {
    init(tdApi result: TDApi.ReportSponsoredResult) {
        switch result {
        case .reportSponsoredResultOk: self = .reported
        case .reportSponsoredResultOptionRequired(let required):
            self = .optionRequired(
                title: required.title,
                options: required.options.map { SponsoredReportOption(id: $0.id, text: $0.text) }
            )
        case .reportSponsoredResultAdsHidden: self = .adsHidden
        case .reportSponsoredResultPremiumRequired: self = .premiumRequired
        case .reportSponsoredResultFailed, .unknown: self = .failed
        }
    }
}
