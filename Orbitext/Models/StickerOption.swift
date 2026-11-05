import Foundation

struct StickerOption: Identifiable, Hashable, Sendable {
    var id: String { fileId }
    let fileId: String
    let emoji: String
    let thumbnailFileId: String?
    let width: Int
    let height: Int

    var isValid: Bool {
        guard let numericId = Int32(fileId), numericId > 0 else { return false }
        return width >= 0 && height >= 0 && width <= Int32.max && height <= Int32.max
    }
}

enum ChatAttachmentError: LocalizedError, Equatable {
    case invalidSticker
    case invalidLocation
    case unsupported

    var errorDescription: String? {
        switch self {
        case .invalidSticker: L10n.string("This sticker is unavailable.")
        case .invalidLocation: L10n.string("Couldn't use this location. Try again.")
        case .unsupported: L10n.string("Attachments are unavailable.")
        }
    }
}
