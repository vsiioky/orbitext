import Foundation

// MARK: - MessageContent from typed TDApi.MessageContent

//
// Translates the generated MessageContent variants into the domain
// MessageContent enum. The generated enum only has the constructors listed
// in scripts/codegen-roots.txt; any other content decodes to .unknown and
// shows as .unsupported, like a listed constructor whose payload TDLib did
// not send.

extension MessageContent {
    init(tdApi content: TDApi.MessageContent) {
        self = Self.map(content)
    }

    private static func map(_ content: TDApi.MessageContent) -> MessageContent {
        switch content {
        case .messageText(let m):
            let formatted = m.text.map(FormattedString.init(tdApi:)) ?? .empty
            return .text(formatted)

        case .messagePhoto(let m):
            let caption = m.caption.map(FormattedString.init(tdApi:)) ?? .empty
            guard let photo = m.photo else { return .unsupported("Photo") }
            let mini = Self.minithumbnailData(photo.minithumbnail)
            // TDLib lists sizes ascending; the largest (best for the
            // watch's pull-up viewer) is the last entry. Matches
            // dict-walk path: `let best = sizes.last`.
            let best = photo.sizes.last
            let fileId = Self.fileIdString(best?.photo)
            let width = Int(best?.width ?? 0)
            let height = Int(best?.height ?? 0)
            return .photo(
                caption: caption, fileId: fileId, width: width, height: height, minithumbnail: mini,
                previewFileId: Self.previewFileId(of: photo.sizes, fullSize: best)
            )

        case .messageVideo(let m):
            let caption = m.caption.map(FormattedString.init(tdApi:)) ?? .empty
            guard let video = m.video else { return .unsupported("Video") }
            let fileId = Self.fileIdString(video.video)
            let thumbId = Self.thumbFileIdString(video.thumbnail)
            let mini = Self.minithumbnailData(video.minithumbnail)
            return .video(
                caption: caption,
                fileId: fileId,
                thumbnailId: thumbId,
                width: Int(video.width),
                height: Int(video.height),
                duration: Int(video.duration),
                minithumbnail: mini
            )

        case .messageVideoNote(let m):
            guard let vn = m.videoNote else { return .unsupported("VideoNote") }
            let fileId = Self.fileIdString(vn.video)
            let thumbId = Self.thumbFileIdString(vn.thumbnail)
            let mini = Self.minithumbnailData(vn.minithumbnail)
            return .videoNote(
                duration: Int(vn.duration),
                fileId: fileId,
                thumbnailId: thumbId,
                minithumbnail: mini
            )

        case .messageVoiceNote(let m):
            guard let voice = m.voiceNote else { return .unsupported("VoiceNote") }
            let fileId = Self.fileIdString(voice.voice)
            let waveform: [UInt8]?
            if voice.waveform.isEmpty {
                waveform = nil
            } else {
                let decoded = TDLibService.decodeTelegramWaveform(voice.waveform)
                waveform = decoded.isEmpty ? nil : decoded
            }
            return .voice(duration: Int(voice.duration), fileId: fileId, waveform: waveform)

        case .messageSticker(let m):
            guard let sticker = m.sticker else { return .unsupported("Sticker") }
            let fileId = Self.fileIdString(sticker.sticker)
            let thumbId = Self.thumbFileIdString(sticker.thumbnail)
            return .sticker(emoji: sticker.emoji, fileId: fileId, thumbnailFileId: thumbId)

        case .messageAnimatedEmoji(let m):
            // Render the animated emoji as a sticker so the existing
            // sticker bubble can show it.
            guard let sticker = m.animatedEmoji?.sticker else { return .unsupported("AnimatedEmoji") }
            let fileId = Self.fileIdString(sticker.sticker)
            let thumbId = Self.thumbFileIdString(sticker.thumbnail)
            return .sticker(emoji: m.emoji, fileId: fileId, thumbnailFileId: thumbId)

        case .messageAnimation(let m):
            guard let anim = m.animation else { return .unsupported("Animation") }
            let fileId = Self.fileIdString(anim.animation)
            let mini = Self.minithumbnailData(anim.minithumbnail)
            return .animation(fileId: fileId, minithumbnail: mini)

        case .messageDocument(let m):
            guard let doc = m.document else { return .unsupported("Document") }
            let fileId = Self.fileIdString(doc.document)
            let size = Int64(doc.document?.size ?? 0)
            let name = doc.fileName.isEmpty ? "document" : doc.fileName
            return .document(name: name, size: size, fileId: fileId)

        case .messageCall(let m):
            let reason = Self.callDiscardReasonTag(m.discardReason)
            return .call(duration: Int(m.duration), isVideo: m.isVideo, discardReason: reason)

        case .messageContact(let m):
            guard let contact = m.contact else { return .unsupported("Contact") }
            let name = [contact.firstName, contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return .contact(name: name, phone: contact.phoneNumber)

        case .messageLocation(let m):
            guard let loc = m.location else { return .unsupported("Location") }
            let live = m.livePeriod > 0 ? Int(m.livePeriod) : nil
            return .location(latitude: loc.latitude, longitude: loc.longitude, livePeriod: live)

        case .messageVenue(let m):
            guard let venue = m.venue else { return .unsupported("Venue") }
            let loc = venue.location
            return .venue(
                latitude: loc?.latitude ?? 0,
                longitude: loc?.longitude ?? 0,
                title: venue.title,
                address: venue.address,
                venueType: venue.type.isEmpty ? nil : venue.type
            )

        case .messagePoll(let m):
            // Only the question is shown; its entities are not rendered.
            return .poll(question: m.poll?.question?.text ?? "")

        case .messageAudio(let m):
            guard let audio = m.audio else { return .unsupported("Audio") }
            let fileId = Self.fileIdString(audio.audio)
            return .audio(
                title: audio.title,
                performer: audio.performer,
                duration: Int(audio.duration),
                fileId: fileId
            )

        case .messagePinMessage:
            return .pinnedMessage

        case .messageBasicGroupChatCreate, .messageSupergroupChatCreate, .messageChatAddMembers:
            // Chat-create *and* add-members both map to .chatCreated, while
            // joinByLink / joinByRequest map to .memberJoined below. Existing
            // tests pin this mapping (testParseSystemMessages).
            return .chatCreated

        case .messageChatJoinByLink, .messageChatJoinByRequest:
            return .memberJoined

        case .messageChatDeleteMember:
            return .memberLeft

        case .unknown(let tag):
            // Drop the `message` prefix: the placeholder names the kind.
            return .unsupported(Self.stripMessagePrefix(tag))
        }
    }

    // MARK: - Helpers (private; type-scoped so they stay testable)

    /// The file a chat draws a photo from: the smallest size that still fills
    /// the thumbnail tile. The full-size file is for the viewer, and a chat of
    /// photos would download every one of them for a tile 120 pt wide. Nil
    /// when no smaller size is wide enough.
    ///
    /// Compared by width: the tile is a fixed width and a tall photo is cropped
    /// to it, so a size that is merely long enough would be stretched.
    private static func previewFileId(of sizes: [TDApi.PhotoSize], fullSize: TDApi.PhotoSize?) -> String? {
        let fillsTheTile = sizes.filter { size in
            guard let file = size.photo, file.id != 0 else { return false }
            return Int(size.width) >= AppConstants.UI.Thumbnail.pixelWidth
        }
        let smallest = fillsTheTile.min { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        guard let preview = smallest?.photo, preview.id != fullSize?.photo?.id else { return nil }
        return fileIdString(preview)
    }

    private static func fileIdString(_ file: TDApi.File?) -> String {
        guard let file else { return "0" }
        return "\(file.id)"
    }

    private static func thumbFileIdString(_ thumb: TDApi.Thumbnail?) -> String? {
        guard let file = thumb?.file, file.id != 0 else { return nil }
        return "\(file.id)"
    }

    private static func minithumbnailData(_ mini: TDApi.Minithumbnail?) -> Data? {
        guard let mini, !mini.data.isEmpty else { return nil }
        return mini.data
    }

    private static func callDiscardReasonTag(_ reason: TDApi.CallDiscardReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .callDiscardReasonEmpty: return "callDiscardReasonEmpty"
        case .callDiscardReasonMissed: return "callDiscardReasonMissed"
        case .callDiscardReasonDeclined: return "callDiscardReasonDeclined"
        case .callDiscardReasonDisconnected: return "callDiscardReasonDisconnected"
        case .callDiscardReasonHungUp: return "callDiscardReasonHungUp"
        case .callDiscardReasonUpgradeToGroupCall: return "callDiscardReasonUpgradeToGroupCall"
        case .unknown(let tag): return tag.isEmpty ? nil : tag
        }
    }

    static func stripMessagePrefix(_ tag: String) -> String {
        if tag.hasPrefix("message") {
            return String(tag.dropFirst("message".count))
        }
        return tag
    }
}
