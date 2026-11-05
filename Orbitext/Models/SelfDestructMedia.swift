import Foundation

/// How a message's media destroys itself once it is opened (TDLib
/// `message.self_destruct_type`). Telegram API Terms of Service 1.4: a client
/// must not keep such content from disappearing, so its media is shown only
/// behind a tap, is never cached, and is gone once the policy says so.
enum SelfDestructPolicy: Equatable, Codable, Sendable {
    /// Opened once, destroyed when closed (`messageSelfDestructTypeImmediately`).
    case viewOnce
    /// Destroyed this many seconds after it was opened (`messageSelfDestructTypeTimer`).
    case timer(seconds: Int)

    init?(tdApi type: TDApi.MessageSelfDestructType?) {
        switch type {
        case .messageSelfDestructTypeImmediately?:
            self = .viewOnce
        case .messageSelfDestructTypeTimer(let timer)?:
            self = .timer(seconds: Int(timer.selfDestructTime))
        case .unknown?, nil:
            return nil
        }
    }

    /// A moment for the player to start and finish, so the end of a voice
    /// note or video is not cut off.
    static let playbackSlack = 2

    /// How long the opened media may stay on screen; nil while the user keeps
    /// it open. Media that plays is played once: at least its length, which
    /// a timer shorter than the media does not cut short. A view-once photo
    /// stays until it is closed.
    func viewingTime(mediaDuration: Int?) -> Duration? {
        let playback = mediaDuration.map { max($0, 1) + Self.playbackSlack }
        switch self {
        case .viewOnce:
            return playback.map { .seconds($0) }
        case .timer(let seconds):
            return .seconds(max(max(seconds, 1), playback ?? 0))
        }
    }
}

/// Which media a self-destructed message held (`messageExpired*`).
enum ExpiredMediaKind: String, Equatable, Codable, Sendable {
    case photo
    case video
    case videoNote
    case voiceNote

    var preview: String {
        switch self {
        case .photo: return L10n.string("Photo expired")
        case .video: return L10n.string("Video expired")
        case .videoNote: return L10n.string("Video message expired")
        case .voiceNote: return L10n.string("Voice message expired")
        }
    }
}

extension MessageContent {
    /// Every file the content draws or plays: what a self-destructing message
    /// must keep out of the caches.
    var mediaFileIds: Set<String> {
        let ids: [String?]
        switch self {
        case .photo(_, let fileId, _, _, _, let previewFileId): ids = [fileId, previewFileId]
        case .video(_, let fileId, let thumbnailId, _, _, _, _): ids = [fileId, thumbnailId]
        case .videoNote(_, let fileId, let thumbnailId, _): ids = [fileId, thumbnailId]
        case .voice(_, let fileId, _): ids = [fileId]
        default: ids = []
        }
        return Set(ids.compactMap(\.self).filter { $0 != "0" })
    }

    /// Seconds the content plays for; nil for content that does not play.
    var playbackDuration: Int? {
        switch self {
        case .video(_, _, _, _, _, let duration, _): return duration
        case .videoNote(let duration, _, _, _): return duration
        case .voice(let duration, _, _): return duration
        default: return nil
        }
    }

    /// What the content becomes once it has destroyed itself; nil for content
    /// Telegram does not let destroy itself.
    var expiredKind: ExpiredMediaKind? {
        switch self {
        case .photo: return .photo
        case .video: return .video
        case .videoNote: return .videoNote
        case .voice: return .voiceNote
        default: return nil
        }
    }
}

extension MessageInfo {
    /// Media the chat shows only as a tap-to-open placeholder.
    var isSelfDestructingMedia: Bool {
        selfDestruct != nil && content.expiredKind != nil
    }
}
