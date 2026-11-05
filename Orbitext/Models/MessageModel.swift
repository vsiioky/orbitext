import Foundation

extension String {
    var normalizedReactionEmoji: String {
        let filtered = unicodeScalars.filter { $0.value != 0xFE0F }
        return String(String.UnicodeScalarView(filtered))
    }
}

enum QuickReactionPreference {
    static let storageKey = "quickReactionEmoji"
    static let defaultEmoji = "👍"
    static let options = ["👍", "❤", "🔥", "😂", "👏", "🎉"]

    static func sanitize(_ emoji: String) -> String {
        let normalizedEmoji = emoji.normalizedReactionEmoji
        if let match = options.first(where: { $0.normalizedReactionEmoji == normalizedEmoji }) {
            return match
        }
        return defaultEmoji
    }

    static func resolve(storedEmoji: String, available: [String]) -> String {
        let preferred = sanitize(storedEmoji)
        for candidate in candidates(for: preferred) {
            let normalizedCandidate = candidate.normalizedReactionEmoji
            if let match = available.first(where: { $0.normalizedReactionEmoji == normalizedCandidate }) {
                return match
            }
        }
        return preferred
    }

    private static func candidates(for emoji: String) -> [String] {
        switch emoji.normalizedReactionEmoji {
        case "❤":
            return ["❤", "❤️"]
        case "😂":
            return ["🤣", "😂", "😆", "😁"]
        default:
            return [emoji.normalizedReactionEmoji]
        }
    }
}

enum MessageContent: Equatable, Codable {
    case text(FormattedString)
    case photo(caption: FormattedString, fileId: String, width: Int, height: Int, minithumbnail: Data?, previewFileId: String? = nil)
    case video(caption: FormattedString, fileId: String, thumbnailId: String?, width: Int, height: Int, duration: Int, minithumbnail: Data?)
    case voice(duration: Int, fileId: String, waveform: [UInt8]?)
    case sticker(emoji: String, fileId: String, thumbnailFileId: String?)
    case animation(fileId: String, minithumbnail: Data?)
    case document(name: String, size: Int64, fileId: String)
    case call(duration: Int, isVideo: Bool, discardReason: String?)
    case contact(name: String, phone: String)
    case location(latitude: Double, longitude: Double, livePeriod: Int?)
    case venue(latitude: Double, longitude: Double, title: String, address: String, venueType: String?)
    case poll(question: String)
    case videoNote(duration: Int, fileId: String, thumbnailId: String?, minithumbnail: Data?)
    case audio(title: String, performer: String, duration: Int, fileId: String)
    case pinnedMessage
    case chatCreated
    case memberJoined
    case memberLeft
    /// Self-destructed media: only the kind of what it was remains.
    case expiredMedia(ExpiredMediaKind)
    case unsupported(String)

    /// One-line summary for the chat list, search, widget, notifications
    /// and reply previews. Spoilers are masked: none of these can reveal them.
    var textPreview: String { preview { $0.maskingSpoilers.text } }

    /// `textPreview` with spoilers in the clear, for VoiceOver once the
    /// user has chosen to reveal them.
    var revealedTextPreview: String { preview(\.text) }

    var hasSpoiler: Bool {
        switch self {
        case .text(let s), .photo(let s, _, _, _, _, _), .video(let s, _, _, _, _, _, _): return s.hasSpoiler
        default: return false
        }
    }

    private func preview(_ render: (FormattedString) -> String) -> String {
        switch self {
        case .text(let s): return render(s)
        case .photo(let c, _, _, _, _, _): return c.isEmpty ? L10n.string("Photo") : render(c)
        case .video(let c, _, _, _, _, let d, _):
            return c.isEmpty ? L10n.string("Video") + " (\(d)s)" : render(c)
        case .voice(let d, _, _): return L10n.string("Voice") + " (\(d)s)"
        case .sticker(let e, _, _): return "\(e) " + L10n.string("Sticker")
        case .animation: return L10n.string("GIF")
        case .document(let n, _, _): return n
        case .call(let d, let isVideo, let reason):
            let type = isVideo ? L10n.string("Video call") : L10n.string("Call")
            if let reason, reason == "callDiscardReasonMissed" { return L10n.string("Missed call") }
            if let reason, reason == "callDiscardReasonDeclined" { return L10n.string("Declined call") }
            if d > 0 { return "\(type) (\(d)s)" }
            return type
        case .contact(let name, _): return "👤 \(name)"
        case .location(_, _, let livePeriod):
            return livePeriod != nil ? L10n.string("Live location") : L10n.string("Location")
        case .venue(_, _, let title, _, _):
            return title.isEmpty ? L10n.string("Location") : title
        case .poll(let q): return "📊 \(q)"
        case .videoNote(let d, _, _, _): return L10n.string("Video message") + " (\(d)s)"
        case .audio(let title, let performer, _, _):
            if !title.isEmpty { return "🎵 \(performer.isEmpty ? title : "\(performer) - \(title)")" }
            return L10n.string("Audio")
        case .pinnedMessage: return L10n.string("Pinned message")
        case .chatCreated: return L10n.string("Chat created")
        case .memberJoined: return L10n.string("Joined the chat")
        case .memberLeft: return L10n.string("Left the chat")
        case .expiredMedia(let kind): return kind.preview
        case .unsupported(let t): return "[\(t)]"
        }
    }

    var isNotifiable: Bool {
        switch self {
        case .unsupported, .pinnedMessage, .chatCreated, .memberJoined, .memberLeft: return false
        default: return true
        }
    }

    var contentHandlesTap: Bool {
        switch self {
        case .photo, .video, .voice, .audio, .videoNote, .sticker:
            return true
        default:
            return false
        }
    }

    var isServiceMessage: Bool {
        switch self {
        case .pinnedMessage, .chatCreated, .memberJoined, .memberLeft:
            return true
        default:
            return false
        }
    }

    var systemImage: String? {
        switch self {
        case .text: return nil
        case .photo: return "photo"
        case .video: return "video"
        case .voice: return "mic"
        case .sticker: return "face.smiling"
        case .animation: return "play.circle"
        case .document: return "doc"
        case .call(_, let isVideo, _): return isVideo ? "video" : "phone"
        case .contact: return "person.circle"
        case .location: return "location"
        case .venue: return "mappin.and.ellipse"
        case .poll: return "chart.bar"
        case .videoNote: return "video.circle"
        case .audio: return "music.note"
        case .pinnedMessage: return "pin"
        case .chatCreated: return "plus.bubble"
        case .memberJoined: return "person.badge.plus"
        case .memberLeft: return "person.badge.minus"
        case .expiredMedia: return "flame"
        case .unsupported: return "questionmark.circle"
        }
    }
}

struct ReactionInfo: Identifiable, Equatable, Codable {
    let key: String
    let emoji: String
    let actionValue: String?
    var count: Int
    var isSelected: Bool

    var id: String { key }

    init(key: String? = nil, emoji: String, actionValue: String? = nil, count: Int, isSelected: Bool) {
        let normalizedActionValue = actionValue?.normalizedReactionEmoji
            ?? (key == nil ? emoji.normalizedReactionEmoji : nil)
        self.key = key ?? "emoji:\(normalizedActionValue ?? "")"
        self.emoji = emoji
        self.actionValue = normalizedActionValue
        self.count = count
        self.isSelected = isSelected
    }

    private enum CodingKeys: String, CodingKey {
        case key, emoji, actionValue, count, isSelected
    }
}

/// Server-authoritative capability flags returned by TDLib's
/// getMessageProperties. Client-side guesses (isOutgoing + content type)
/// miss real constraints: channels can restrict edits, the 48h edit
/// window, and group-admin delete-for-everyone permissions.
struct MessageProperties: Equatable, Codable, Sendable {
    var canBeEdited = false
    var canBeDeletedOnlyForSelf = false
    var canBeDeletedForAllUsers = false
    var canBeForwarded = true
    var canBeReplied = true
    var canBeSaved = true
    var canBePinned = false

    /// Set to true once TDLib's getMessageProperties has returned for
    /// this message. Until then, .isEditable falls back to the
    /// client-side heuristic to keep the menu usable while the
    /// round-trip is in flight.
    var isResolved = false

    static let `default` = MessageProperties()
}

struct MessageSendFailure: Equatable, Codable, Sendable {
    let code: Int
    let message: String
}

enum MessageDeliveryState: Equatable {
    case sending, sent, read, failed

    var accessibilityLabel: String {
        switch self {
        case .sending: return L10n.string("Sending")
        case .sent: return L10n.string("Sent")
        case .read: return L10n.string("Read")
        case .failed: return L10n.string("Failed")
        }
    }
}

struct MessageInfo: Identifiable, Equatable, Codable {
    let id: Int64
    let chatId: Int64
    var senderName: String
    var senderId: Int64
    var content: MessageContent
    var date: Date
    var isOutgoing: Bool
    var isRead: Bool
    var replyToMessageId: Int64? = nil
    var replyToSenderName: String? = nil
    var replyToSenderUserId: Int64? = nil
    var replyToPreview: FormattedString? = nil
    var forwardedOrigin: MessageOrigin? = nil
    var reactions: [ReactionInfo] = []

    /// TDLib media_album_id. Non-zero for messages that belong to a
    /// photo/video album (TDLib batches related media uploads under
    /// the same id). 0 means the message stands on its own. Used by
    /// MessageAlbumInfo.group(_:) to coalesce consecutive media into a
    /// single mosaic row in the chat list.
    var mediaAlbumId: Int64 = 0

    // Explicit resolution flags so the NameResolver does not have to compare
    // senderName / replyToSenderName against the localised placeholder
    // string ("User") - a comparison that silently breaks when the
    // placeholder is localised or when a real sender happens to be named
    // "User". Default to `true` so messages we already populate fully are
    // never accidentally re-resolved; parseMessageInfo flips these to false
    // when it inserts a placeholder for an un-cached sender.
    var senderResolved = true
    var replyToSenderResolved = true

    /// True while TDLib still holds a temporary local id for this message
    /// (sending_state == messageSendingStatePending). Operations that go
    /// through Telegram (reactions, edits, forwarding) cannot use the
    /// temp id and would return "Message not found"; the UI uses this
    /// flag to disable those affordances until updateMessageSendSucceeded
    /// promotes the message to a real server id.
    var isSending = false
    /// Optional for backwards-compatible decoding of existing chat snapshots.
    var sendingFailure: MessageSendFailure? = nil
    /// Bot keyboard attached to the message. Kept current by
    /// updateMessageEdited; optional for the same snapshot compatibility.
    var replyMarkup: ReplyMarkup? = nil
    /// Set when the media destroys itself after it is opened; optional for
    /// the same snapshot compatibility.
    var selfDestruct: SelfDestructPolicy? = nil

    var deliveryState: MessageDeliveryState {
        if sendingFailure != nil { return .failed }
        if isSending { return .sending }
        return isRead ? .read : .sent
    }

    /// Server-authoritative permissions. Populated lazily by
    /// ChatMessageStore.fetchMessageProperties when the user opens a
    /// per-message menu; until then this is .default and views fall
    /// back on the client-side `isEditable` heuristic.
    var properties: MessageProperties = .default

    var isForwarded: Bool { forwardedOrigin != nil }
    var forwardedFrom: String? { forwardedOrigin?.displayName }
    var viewID: String { "\(chatId):\(id)" }

    var hasReplyPreview: Bool {
        replyToMessageId != nil && (replyToSenderName != nil || replyToPreview != nil)
    }

    var isEditable: Bool {
        guard !isSending, sendingFailure == nil else { return false }
        if properties.isResolved { return properties.canBeEdited }
        // Client-side fallback used until TDLib's getMessageProperties
        // resolves: outgoing, non-forwarded text. The server flag will
        // override this once the menu opens.
        guard isOutgoing, !isForwarded else { return false }
        if case .text = content { return true }
        return false
    }

    var currentText: String? {
        if case .text(let s) = content { return s.text }
        return nil
    }

    /// Localized one-line summary for system messages rendered as
    /// centered pills. nil for non-service content.
    var servicePillText: String? {
        let name = senderName
        switch content {
        case .pinnedMessage: return L10n.format("%@ pinned a message", name)
        case .chatCreated: return L10n.format("%@ created the chat", name)
        case .memberJoined: return L10n.format("%@ joined the chat", name)
        case .memberLeft: return L10n.format("%@ left the chat", name)
        default: return nil
        }
    }
}
