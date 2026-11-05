import Foundation

// MARK: - Sponsored messages (Telegram API Terms of Service 3.3)

extension TDLibService {
    func getChatSponsoredMessages(chatId: Int64) async throws -> SponsoredMessageBatch {
        let result = try await throttledSend([
            "@type": "getChatSponsoredMessages",
            "chat_id": chatId
        ])
        return SponsoredMessageBatch(tdApi: TDApi.decodeSponsoredMessages(result), chatId: chatId)
    }

    /// td_api.tl has no viewSponsoredMessage any more: an ad is viewed like
    /// any message, once its whole text is on screen. Not a read receipt, so
    /// no force_read.
    func viewSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": [messageId],
            "force_read": false
        ])
    }

    func clickSponsoredMessage(chatId: Int64, messageId: Int64) async throws {
        _ = try await throttledSend([
            "@type": "clickChatSponsoredMessage",
            "chat_id": chatId,
            "message_id": messageId,
            "is_media_click": false,
            "from_fullscreen": false
        ])
    }

    /// `optionId` is empty for the first request; TDLib answers with the
    /// options to choose from when it needs one.
    func reportSponsoredMessage(chatId: Int64, messageId: Int64, optionId: Data) async throws -> SponsoredReportResult {
        let result = try await throttledSend([
            "@type": "reportChatSponsoredMessage",
            "chat_id": chatId,
            "message_id": messageId,
            "option_id": optionId.base64EncodedString()
        ])
        return SponsoredReportResult(tdApi: TDApi.decodeReportSponsoredResult(result))
    }
}
