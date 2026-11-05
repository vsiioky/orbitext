import Foundation

/// An ad TDLib gives a channel (Telegram API Terms of Service 3.3). The watch
/// shows its title, text and sponsor details, never its media: TDLib asks for
/// media to be fully downloaded before the ad is shown.
struct SponsoredMessage: Identifiable, Equatable, Sendable {
    let chatId: Int64
    let messageId: Int64
    /// Labeled "Recommended" instead of "Sponsored".
    let isRecommended: Bool
    let canBeReported: Bool
    let title: String
    let text: FormattedString
    let buttonText: String
    /// Where the button leads: a t.me link or a web page.
    let url: String
    let sponsorInfo: String
    let additionalInfo: String

    var id: Int64 { messageId }

    var label: String {
        isRecommended ? L10n.string("Recommended") : L10n.string("Sponsored")
    }
}

/// One answer of `getChatSponsoredMessages`.
struct SponsoredMessageBatch: Equatable, Sendable {
    let messages: [SponsoredMessage]
    /// The fewest ordinary messages between two ads; 0 means one ad after
    /// all ordinary messages.
    let messagesBetween: Int
}

struct SponsoredReportOption: Identifiable, Equatable, Sendable {
    let id: Data
    let text: String
}

/// The outcome of `reportChatSponsoredMessage`.
enum SponsoredReportResult: Equatable, Sendable {
    case reported
    /// The ad is too old or gone.
    case failed
    /// Ask again with one of these options.
    case optionRequired(title: String, options: [SponsoredReportOption])
    case adsHidden
    case premiumRequired
}
