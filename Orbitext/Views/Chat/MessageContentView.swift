import SwiftUI

struct MessageContentView: View {
    let content: MessageContent
    let isOutgoing: Bool
    var voicePlaybackRequest: Int?

    var body: some View {
        switch content {
        case .text(let formatted):
            MessageTextView(formatted: formatted, isOutgoing: isOutgoing)

        case .photo(let caption, let fileId, let width, let height, let minithumbnail, let previewFileId):
            VStack(alignment: .leading, spacing: 2) {
                PhotoThumbnailView(
                    fileId: fileId, width: width, height: height, minithumbnail: minithumbnail, previewFileId: previewFileId
                )
                if !caption.isEmpty {
                    MessageTextView(formatted: caption, isOutgoing: isOutgoing)
                }
            }

        case .video(let caption, let fileId, let thumbnailId, let width, let height, let duration, let minithumbnail):
            VStack(alignment: .leading, spacing: 4) {
                VideoThumbnailView(
                    fileId: fileId,
                    thumbnailId: thumbnailId,
                    width: width,
                    height: height,
                    duration: duration,
                    style: .video,
                    minithumbnail: minithumbnail
                )
                if !caption.isEmpty {
                    MessageTextView(formatted: caption, isOutgoing: isOutgoing)
                }
            }

        case .voice(let duration, let fileId, let waveform):
            VoicePlayerView(
                fileId: fileId, duration: duration, waveform: waveform,
                isOutgoing: isOutgoing, playbackRequest: voicePlaybackRequest
            )
            .id(fileId)
            // The enclosing message owns taps, including its timestamp and padding.
            .allowsHitTesting(voicePlaybackRequest == nil)

        case .audio(let title, let performer, let duration, let fileId):
            VStack(alignment: .leading, spacing: 4) {
                if !title.isEmpty || !performer.isEmpty {
                    Text(performer.isEmpty ? title : "\(performer) - \(title)")
                        .font(.system(size: AppConstants.UI.FontSize.body, weight: .medium))
                        .foregroundStyle(isOutgoing ? .white : WristTheme.Palette.primaryText)
                        .lineLimit(2)
                }
                VoicePlayerView(fileId: fileId, duration: duration, isOutgoing: isOutgoing)
                    .id(fileId)
            }

        case .videoNote(let duration, let fileId, let thumbnailId, let minithumbnail):
            VideoThumbnailView(
                fileId: fileId,
                thumbnailId: thumbnailId,
                width: Int(AppConstants.UI.Sticker.size),
                height: Int(AppConstants.UI.Sticker.size),
                duration: duration,
                style: .videoNote,
                minithumbnail: minithumbnail
            )

        case .sticker(let emoji, let fileId, let thumbnailFileId):
            StickerView(emoji: emoji, fileId: fileId, thumbnailFileId: thumbnailFileId)

        case .location(let lat, let lng, let livePeriod):
            LocationMessageView(latitude: lat, longitude: lng, livePeriod: livePeriod)

        case .venue(let lat, let lng, let title, let address, let type):
            LocationMessageView(
                latitude: lat,
                longitude: lng,
                livePeriod: nil,
                venueTitle: title,
                venueAddress: address,
                venueType: type
            )

        default:
            HStack(spacing: 4) {
                if let icon = content.systemImage {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(content.textPreview)
                    .font(.caption2)
            }
            .foregroundStyle(isOutgoing ? .white : WristTheme.Palette.secondaryText)
        }
    }
}
