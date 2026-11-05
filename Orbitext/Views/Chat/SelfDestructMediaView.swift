import SwiftUI

extension EnvironmentValues {
    /// Set by the chat screen: opens self-destructing media in a viewer the
    /// screen hosts, so the viewer outlives the row once the media expires.
    @Entry var openSelfDestructMedia: @MainActor (MessageInfo) -> Void = { _ in }
}

/// The bubble content of self-destructing media (Telegram API Terms of
/// Service 1.4): no thumbnail, only what it is and how it destroys itself.
struct SelfDestructMediaView: View {
    @Environment(\.openSelfDestructMedia) private var openSelfDestructMedia
    let message: MessageInfo

    var body: some View {
        Button {
            openSelfDestructMedia(message)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: message.selfDestruct == .viewOnce ? "1.circle" : "flame")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.content.selfDestructTitle)
                        .font(.system(size: AppConstants.UI.FontSize.body, weight: .medium))
                    Text(policyText)
                        .font(.caption2)
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.8) : WristTheme.Palette.secondaryText)
                    if !message.isOutgoing {
                        Text(L10n.string("Tap to open"))
                            .font(.caption2)
                            .foregroundStyle(WristTheme.Palette.accent)
                    }
                }
            }
            .foregroundStyle(message.isOutgoing ? .white : WristTheme.Palette.primaryText)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        // Telegram does not let the sender open it again either.
        .disabled(message.isOutgoing)
        .accessibilityLabel("\(message.content.selfDestructTitle), \(policyText)")
        .accessibilityHint(message.isOutgoing ? "" : L10n.string("Tap to open"))
    }

    private var policyText: String {
        switch message.selfDestruct {
        case .timer(let seconds)?: return L10n.format("Disappears %lld s after opening", Int64(seconds))
        case .viewOnce?, nil: return L10n.string("View once")
        }
    }
}

private extension MessageContent {
    var selfDestructTitle: String {
        switch self {
        case .photo: return L10n.string("Photo")
        case .video: return L10n.string("Video")
        case .videoNote: return L10n.string("Video message")
        case .voice: return L10n.string("Voice")
        default: return textPreview
        }
    }
}

/// The opened media, full screen, for as long as its policy allows.
///
/// The file is loaded first; only then is TDLib told the content was opened
/// (`openMessageContent`, which starts the destruction on the server) and the
/// viewing time starts, so a slow download does not use it up. Nothing is
/// cached: the photo is decoded for this view only, the voice note plays from
/// memory, and the video's playback copy is deleted when the viewer closes.
/// Closing it leaves nothing to open again.
struct SelfDestructMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(ChatMessageStore.self) private var chatMessageStore
    @Environment(ImageCache.self) private var imageCache
    @Environment(VoiceManager.self) private var voiceManager
    let message: MessageInfo

    private enum Phase {
        case loading
        case photo(UIImage)
        case video(URL)
        case voice
        case failed
    }

    @State private var phase = Phase.loading
    @State private var didOpen = false

    var body: some View {
        content
            .task { await open() }
            .onChange(of: isVoiceActive) { wasActive, isActive in
                // A view-once voice note is heard once: the viewer closes
                // when it ends instead of offering to play it again.
                if wasActive, !isActive { dismiss() }
            }
            .onDisappear(perform: close)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .photo(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(L10n.string("Photo"))
        case .video(let url):
            WatchInlineMoviePlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .voice:
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(WristTheme.Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: isVoiceActive)
                .accessibilityLabel(L10n.string("Voice"))
        case .failed:
            Text(L10n.string("Media could not be opened"))
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
    }

    private var isVoiceActive: Bool {
        guard case .voice(_, let fileId, _) = message.content else { return false }
        return voiceManager.isPlaying(fileId: fileId) || voiceManager.isPaused(fileId: fileId)
    }

    private func open() async {
        imageCache.excludeFromCache(fileIds: message.content.mediaFileIds)
        let loaded = await load()
        guard !Task.isCancelled else { return }
        guard let loaded else {
            phase = .failed
            return
        }
        phase = loaded
        didOpen = true
        let service = chatRepository.service
        let chatId = message.chatId, messageId = message.id
        Task { await service.openMessageContent(chatId: chatId, messageId: messageId) }

        guard let time = message.selfDestruct?.viewingTime(mediaDuration: message.content.playbackDuration) else { return }
        try? await Task.sleep(for: time)
        guard !Task.isCancelled else { return }
        dismiss()
    }

    private func load() async -> Phase? {
        switch message.content {
        case .photo(_, let fileId, _, _, _, _):
            return await imageCache.loadFullSize(fileId: fileId).map(Phase.photo)
        case .video(_, let fileId, _, _, _, _, _), .videoNote(_, let fileId, _, _):
            return await imageCache.loadSharedPlaybackFile(fileId: fileId).map(Phase.video)
        case .voice(_, let fileId, _):
            guard let data = await imageCache.loadData(fileId: fileId, priority: .requested),
                  !Task.isCancelled, voiceManager.play(data: data, fileId: fileId) else { return nil }
            return .voice
        default:
            return nil
        }
    }

    private func close() {
        if isVoiceActive { voiceManager.stop() }
        // Drops the playback copy of a video.
        imageCache.excludeFromCache(fileIds: message.content.mediaFileIds)
        guard didOpen else { return }
        chatMessageStore.expireSelfDestructingMedia(chatId: message.chatId, messageId: message.id)
    }
}
