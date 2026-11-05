import Foundation

/// Coalesced view of a TDLib media album (two or more consecutive
/// messages sharing the same non-zero `media_album_id`). The album is
/// rendered as a single mosaic bubble in the chat list instead of N
/// per-photo rows - critical on the watch where 4-10 separate rows
/// chew through the scroll viewport.
///
/// `messages` keeps the original chronological order so reply / sender
/// metadata stays in sync with the first message of the group (TDLib
/// attaches replies to the leading message of an album).
struct MessageAlbumInfo: Identifiable, Equatable {
    let albumId: Int64
    var messages: [MessageInfo]

    var id: String { "album:\(albumId)" }

    var firstMessage: MessageInfo? { messages.first }

    var senderId: Int64 { firstMessage?.senderId ?? 0 }
    var senderName: String { firstMessage?.senderName ?? "" }
    var date: Date { firstMessage?.date ?? .distantPast }
    var isOutgoing: Bool { firstMessage?.isOutgoing ?? false }
    var chatId: Int64 { firstMessage?.chatId ?? 0 }

    /// Albums normally carry the caption on exactly one of the photos
    /// (usually the first non-empty one). Pick the first non-empty
    /// caption so the bubble shows a single caption line.
    var caption: FormattedString? {
        for msg in messages {
            switch msg.content {
            case .photo(let c, _, _, _, _, _) where !c.isEmpty: return c
            case .video(let c, _, _, _, _, _, _) where !c.isEmpty: return c
            default: continue
            }
        }
        return nil
    }

    /// File IDs for the photo / video thumbnails in display order.
    /// AlbumView iterates this when building its mosaic. Non-photo /
    /// non-video items are skipped (TDLib only groups media in albums
    /// anyway, but be defensive).
    var thumbnails: [AlbumThumbnail] {
        messages.compactMap { AlbumThumbnail(message: $0) }
    }
}

struct AlbumThumbnail: Identifiable, Equatable {
    let messageId: Int64
    let fileId: String
    let width: Int
    let height: Int
    /// TDLib `minithumbnail.data` propagated from the source message so
    /// the mosaic can render a blurred placeholder before the real file
    /// finishes downloading.
    let minithumbnail: Data?
    /// A smaller file of the same photo for the mosaic cell; the gallery
    /// opens `fileId`. Nil when the photo has no size worth drawing but the
    /// full one, and for a video, whose `fileId` is already its poster.
    let previewFileId: String?

    var id: Int64 { messageId }

    init?(message: MessageInfo) {
        switch message.content {
        case .photo(_, let fileId, let width, let height, let mini, let previewFileId):
            self.messageId = message.id
            self.fileId = fileId
            self.width = width
            self.height = height
            self.minithumbnail = mini
            self.previewFileId = previewFileId
        case .video(_, _, let thumbnailId, let width, let height, _, let mini):
            // Show the video thumbnail in the mosaic. Tap-through is
            // handled by AlbumView; the gallery picks the real video
            // file id when the user taps to play.
            self.messageId = message.id
            self.fileId = thumbnailId ?? ""
            self.width = width
            self.height = height
            self.minithumbnail = mini
            self.previewFileId = nil
        default:
            return nil
        }
    }
}

/// One row in the chat list. Either a stand-alone message (text, voice,
/// service, single photo) or a coalesced album bubble. `ChatView`
/// constructs `[ChatItem]` from the raw message store via
/// `MessageAlbumInfo.group(_:)` and `ChatMessageListView` dispatches on
/// the case.
enum ChatItem: Identifiable, Equatable {
    case message(MessageInfo)
    case album(MessageAlbumInfo)

    var id: String {
        switch self {
        case .message(let m): return "msg:\(m.viewID)"
        case .album(let a): return a.id
        }
    }

    /// The id `ChatMessageListView` gives this row, for `ScrollViewProxy`.
    var scrollID: String {
        switch self {
        case .message(let m): return m.viewID
        case .album(let a): return a.id
        }
    }

    func contains(messageId: Int64) -> Bool {
        switch self {
        case .message(let m): return m.id == messageId
        case .album(let a): return a.messages.contains { $0.id == messageId }
        }
    }

    /// The trailing/anchor message id used for date-separator and
    /// scroll-anchor logic. For albums we anchor on the last (most
    /// recent) message, matching the visual position of the bubble.
    var anchorMessageId: Int64 {
        switch self {
        case .message(let m): return m.id
        case .album(let a): return a.messages.last?.id ?? 0
        }
    }

    var date: Date {
        switch self {
        case .message(let m): return m.date
        case .album(let a): return a.date
        }
    }
}

extension MessageAlbumInfo {
    /// Walk a chronologically ordered message array and collapse runs
    /// of messages with the same non-zero `mediaAlbumId` into
    /// `ChatItem.album`. Singleton media (or media whose sibling has
    /// not yet arrived from TDLib's update stream) stays as
    /// `ChatItem.message` - the next call rebuilds the grouping once
    /// the second album sibling lands, so no debouncing is needed in
    /// the store layer.
    ///
    /// Edge cases:
    /// - A single message left alive after the user deletes the rest
    ///   of an album falls back to `.message` because the run length is 1.
    /// - Album messages can be interleaved with non-album messages
    ///   only when TDLib delivers updates out of order; we still
    ///   coalesce by walking consecutive runs.
    static func group(_ messages: [MessageInfo]) -> [ChatItem] {
        guard !messages.isEmpty else { return [] }
        var items: [ChatItem] = []
        var i = 0
        while i < messages.count {
            let albumId = messages[i].mediaAlbumId
            if albumId == 0 {
                items.append(.message(messages[i]))
                i += 1
                continue
            }
            var j = i + 1
            while j < messages.count && messages[j].mediaAlbumId == albumId {
                j += 1
            }
            let run = Array(messages[i..<j])
            if run.count == 1 {
                items.append(.message(run[0]))
            } else {
                items.append(.album(MessageAlbumInfo(albumId: albumId, messages: run)))
            }
            i = j
        }
        return items
    }
}
