import Foundation

/// Common surface for "anything TDLib hands us that backs a picture":
/// chat photos, message photos, video posters, profile photos. Lets
/// the UI request a small fileId for inline previews, a big fileId
/// for full-screen viewers, and a minithumbnail blob to render a
/// blurred placeholder while either download completes.
///
/// Conformers expose:
/// - `minithumbnail`: optional 8 KB JPEG bytes from TDLib (max 40x40)
/// - `smallFileId`: stringified file id for the low-res thumbnail
/// - `bigFileId`: stringified file id for the full-resolution asset
///
/// Either id may be empty when the underlying payload only carries one
/// size (e.g. messageAnimation has a single file). Callers should fall
/// back via `bigFileId ?? smallFileId` when picking what to download.
///
/// Note: spec also lists `ChatPhotoInfo` and `ProfilePhoto`. Those TDLib
/// shapes are not modelled in our codebase yet, so this file only
/// conforms what we have today (`MessageContent` photo/video/videoNote/
/// animation, and `AlbumThumbnail`). Add new conformances here when
/// those types land - the protocol is intentionally narrow so the
/// surface stays trivial.
protocol TDImageSource {
    var minithumbnail: Data? { get }
    var smallFileId: String? { get }
    var bigFileId: String? { get }
}

extension MessageContent: TDImageSource {
    var minithumbnail: Data? {
        switch self {
        case .photo(_, _, _, _, let mini, _): return mini
        case .video(_, _, _, _, _, _, let mini): return mini
        case .videoNote(_, _, _, let mini): return mini
        case .animation(_, let mini): return mini
        default: return nil
        }
    }

    var smallFileId: String? {
        switch self {
        case .photo(_, let fileId, _, _, _, let previewFileId):
            if let previewFileId, !previewFileId.isEmpty { return previewFileId }
            return fileId.isEmpty ? nil : fileId
        case .video(_, _, let thumbnailId, _, _, _, _),
             .videoNote(_, _, let thumbnailId, _):
            guard let thumbnailId, !thumbnailId.isEmpty else { return nil }
            return thumbnailId
        case .animation(let fileId, _):
            return fileId.isEmpty ? nil : fileId
        default:
            return nil
        }
    }

    var bigFileId: String? {
        switch self {
        case .photo(_, let fileId, _, _, _, _),
             .video(_, let fileId, _, _, _, _, _),
             .videoNote(_, let fileId, _, _),
             .animation(let fileId, _):
            return fileId.isEmpty ? nil : fileId
        default:
            return nil
        }
    }
}

extension AlbumThumbnail: TDImageSource {
    var smallFileId: String? {
        if let previewFileId, !previewFileId.isEmpty { return previewFileId }
        return bigFileId
    }

    var bigFileId: String? {
        // AlbumThumbnail collapses photo & video into a single "show
        // this in the mosaic" handle; the original message holds the
        // real video file. A video's small and big id are the same
        // record - the gallery resolves the real video file separately
        // when the user taps through.
        fileId.isEmpty ? nil : fileId
    }
}
