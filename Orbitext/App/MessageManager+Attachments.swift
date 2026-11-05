import Foundation

extension MessageManager {
    /// Keep load failures visible to the picker so it can offer an explicit retry.
    func loadRecentStickers() async throws -> [StickerOption] {
        try Task.checkCancellation()
        return try await service.getRecentStickers()
    }

    @discardableResult
    func sendSticker(chatId: Int64, sticker: StickerOption) async -> Bool {
        do {
            try Task.checkCancellation()
            guard sticker.isValid else { throw ChatAttachmentError.invalidSticker }
            _ = try await service.sendSticker(chatId: chatId, sticker: sticker)
            HapticManager.messageSent()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return false
        }
    }

    @discardableResult
    func sendLocation(chatId: Int64, location: SharedLocation) async -> Bool {
        do {
            try Task.checkCancellation()
            guard location.isValid else { throw ChatAttachmentError.invalidLocation }
            _ = try await service.sendLocation(chatId: chatId, location: location)
            HapticManager.messageSent()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return false
        }
    }
}
