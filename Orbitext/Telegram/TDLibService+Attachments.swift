import Foundation

extension TDLibService {
    func getRecentStickers() async throws -> [StickerOption] {
        try await TDLibAttachmentRequests.loadStickers { request in
            try await self.throttledSend(request)
        }
    }

    func sendSticker(chatId: Int64, sticker: StickerOption) async throws -> MessageInfo {
        try Task.checkCancellation()
        let request = try TDLibAttachmentRequests.sticker(chatId: chatId, sticker: sticker)
        let result = try await throttledSend(request)
        guard let message = parseMessageInfo(result), message.chatId == chatId else {
            throw TDError.unexpectedResponse
        }
        return message
    }

    func sendLocation(chatId: Int64, location: SharedLocation) async throws -> MessageInfo {
        try Task.checkCancellation()
        let request = try TDLibAttachmentRequests.location(chatId: chatId, location: location)
        let result = try await throttledSend(request)
        guard let message = parseMessageInfo(result), message.chatId == chatId else {
            throw TDError.unexpectedResponse
        }
        return message
    }
}

/// TDLib attachment boundary. Pure payload construction is kept separate from
/// transport so tests can check real wire fields without an authenticated account.
enum TDLibAttachmentRequests {
    static let stickerLimit = 40

    static func sticker(chatId: Int64, sticker: StickerOption) throws -> [String: Any] {
        guard sticker.isValid, let fileId = Int32(sticker.fileId) else {
            throw ChatAttachmentError.invalidSticker
        }
        return [
            "@type": "sendMessage",
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageSticker",
                "sticker": ["@type": "inputFileId", "id": fileId] as [String: Any],
                "width": sticker.width,
                "height": sticker.height,
                "emoji": sticker.emoji
            ] as [String: Any]
        ]
    }

    static func location(chatId: Int64, location: SharedLocation) throws -> [String: Any] {
        guard location.isValid else { throw ChatAttachmentError.invalidLocation }
        return [
            "@type": "sendMessage",
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageLocation",
                "location": [
                    "@type": "location",
                    "latitude": location.latitude,
                    "longitude": location.longitude,
                    "horizontal_accuracy": location.horizontalAccuracy
                ] as [String: Any],
                "live_period": 0,
                "heading": 0,
                "proximity_alert_radius": 0
            ] as [String: Any]
        ]
    }

    static func loadStickers(
        send: (sending [String: Any]) async throws -> [String: Any]
    ) async throws -> [StickerOption] {
        var options: [StickerOption] = []
        var seen: Set<String> = []
        var firstError: (any Error)?
        // Each request is built for its send, which takes it over.
        let requests: [@Sendable () -> [String: Any]] = [
            { ["@type": "getFavoriteStickers"] },
            { ["@type": "getRecentStickers", "is_attached": false] }
        ]

        for makeRequest in requests {
            try Task.checkCancellation()
            do {
                let response = try await send(makeRequest())
                try Task.checkCancellation()
                let parsed = try parseStickers(response)
                for sticker in parsed where seen.insert(sticker.id).inserted {
                    options.append(sticker)
                    if options.count == stickerLimit { return options }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // A useful partial list is preferable to hiding all available stickers.
        // An empty list with a failed source is not proof of an empty account.
        if options.isEmpty, let firstError { throw firstError }
        return options
    }

    static func parseStickers(_ response: [String: Any]) throws -> [StickerOption] {
        guard response["@type"] as? String == "stickers",
              let stickers = response["stickers"] as? [[String: Any]] else {
            throw TDError.unexpectedResponse
        }
        let parsed = stickers.compactMap { value -> StickerOption? in
            guard let file = value["sticker"] as? [String: Any],
                  let fileId = file["id"] as? Int, fileId > 0, fileId <= Int32.max,
                  let width = value["width"] as? Int,
                  let height = value["height"] as? Int else { return nil }
            let thumbnail = value["thumbnail"] as? [String: Any]
            let thumbnailFile = thumbnail?["file"] as? [String: Any]
            let thumbnailId = thumbnailFile?["id"] as? Int
            let option = StickerOption(
                fileId: String(fileId),
                emoji: value["emoji"] as? String ?? "",
                thumbnailFileId: thumbnailId.flatMap { $0 > 0 && $0 <= Int32.max ? String($0) : nil },
                width: width,
                height: height
            )
            return option.isValid ? option : nil
        }
        guard stickers.isEmpty || !parsed.isEmpty else { throw TDError.unexpectedResponse }
        return parsed
    }
}
