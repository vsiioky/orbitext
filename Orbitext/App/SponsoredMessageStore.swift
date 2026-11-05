import Foundation
import Observation
import os

/// The ad shown at the end of a channel's timeline (Telegram API Terms of
/// Service 3.3: a client showing channel content shows its sponsored
/// messages). One ad per channel, after the newest message, which is what
/// TDLib asks for when `messages_between` is 0 and never closer together
/// than any larger value.
@MainActor
@Observable
final class SponsoredMessageStore {
    private let service: TelegramServiceProtocol
    private var adsByChatId: [Int64: SponsoredMessage] = [:]
    @ObservationIgnored private var viewedAds: Set<MessageKey> = []

    init(service: TelegramServiceProtocol) {
        self.service = service
    }

    func message(for chatId: Int64) -> SponsoredMessage? {
        adsByChatId[chatId]
    }

    /// Asks TDLib for the channel's ads each time the channel is opened; a
    /// chat that is no channel has none and is not asked.
    func load(chatId: Int64, isChannel: Bool) async {
        guard isChannel else { return }
        do {
            let batch = try await service.getChatSponsoredMessages(chatId: chatId)
            adsByChatId[chatId] = batch.messages.first
        } catch is CancellationError {
            // The screen left; what it showed stays for its return.
        } catch {
            adsByChatId[chatId] = nil
            Logger.app.debug("No sponsored messages for a channel: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Once per ad: the row stays on screen while the timeline moves.
    func markViewed(_ ad: SponsoredMessage) async {
        let key = MessageKey(chatId: ad.chatId, messageId: ad.messageId)
        guard viewedAds.insert(key).inserted else { return }
        do {
            try await service.viewSponsoredMessage(chatId: ad.chatId, messageId: ad.messageId)
        } catch {
            viewedAds.remove(key)
            Logger.app.debug("viewMessages for an ad failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reports the click and returns the sponsor's link to open.
    func click(_ ad: SponsoredMessage) async -> URL? {
        do {
            try await service.clickSponsoredMessage(chatId: ad.chatId, messageId: ad.messageId)
        } catch {
            Logger.app.debug("clickChatSponsoredMessage failed: \(error.localizedDescription, privacy: .public)")
        }
        return URL(string: ad.url)
    }

    /// An ad that is reported, or ads the user hid, leave the chat.
    func report(_ ad: SponsoredMessage, optionId: Data) async -> SponsoredReportResult {
        let result: SponsoredReportResult
        do {
            result = try await service.reportSponsoredMessage(chatId: ad.chatId, messageId: ad.messageId, optionId: optionId)
        } catch {
            Logger.app.debug("reportChatSponsoredMessage failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        switch result {
        case .reported, .adsHidden:
            adsByChatId[ad.chatId] = nil
        case .failed, .optionRequired, .premiumRequired:
            break
        }
        return result
    }

    func resetAll() {
        adsByChatId.removeAll()
        viewedAds.removeAll()
    }
}
