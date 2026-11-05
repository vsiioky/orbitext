import SwiftUI

struct VoicePlayerView: View {
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(ImageCache.self) private var imageCache
    @Environment(ChatRepository.self) private var chatRepository
    let fileId: String
    let duration: Int
    /// TDLib voice waveform peaks (0..31). nil while waveform metadata
    /// has not arrived yet - WaveformView falls back to an animated
    /// sine placeholder in that case.
    var waveform: [UInt8]?
    var isOutgoing = false
    /// A message-level tap also reaches the player when it lands on the footer or padding.
    var playbackRequest: Int?
    // Optional message coordinates so we can tell TDLib via openMessageContent
    // that this voice was played (marks it as listened across devices).
    // Default-nil to keep existing call sites compiling until MessageContentView
    // wiring lands in a later wave.
    var chatId: Int64?
    var messageId: Int64?

    @State private var audioData: Data?
    /// Only while the file downloads, which starts when the user plays it.
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var pendingPlaybackRequest: UUID?
    /// While the transport is asked whether it holds the file already.
    @State private var isLookingForHeldFile = false
    /// The user tapped while that question was open: play what the answer
    /// brings, or download it if the answer is nothing.
    @State private var playsOnceHeldFileIsFound = false
    /// How many times the user has asked for the file. Zero until the first
    /// tap: a voice message may never be played, and an audio file is
    /// megabytes, so nothing is downloaded before then.
    @State private var downloadRequests = 0
    @State private var requester = UUID()

    private struct LoadRequest: Hashable {
        let fileId: String
        let downloadRequests: Int
    }

    private var hasValidFileId: Bool {
        !fileId.isEmpty && fileId != "0"
    }

    private var isThisPlaying: Bool {
        voiceManager.isPlaying(fileId: fileId)
    }

    private var hasPlaybackPosition: Bool {
        isThisPlaying || voiceManager.isPaused(fileId: fileId)
    }

    private var controlColor: Color {
        isOutgoing ? .white : WristTheme.Palette.accent
    }

    private var secondaryColor: Color {
        isOutgoing ? .white.opacity(0.75) : WristTheme.Palette.secondaryText
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(controlColor)
                } else {
                    Image(systemName: loadFailed ? "arrow.clockwise" : (isThisPlaying ? "pause.fill" : "play.fill"))
                        .font(.caption)
                        .foregroundStyle(controlColor)
                }
            }
            .frame(width: 20)

            Group {
                if isLoading || loadFailed {
                    Text(L10n.string(isLoading ? "Loading..." : "Tap to retry"))
                        .font(.system(size: AppConstants.UI.FontSize.small))
                        .foregroundStyle(secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WaveformView(
                        peaks: waveform,
                        progress: hasPlaybackPosition ? voiceManager.playbackProgress : 0,
                        barColor: secondaryColor.opacity(0.6),
                        playedColor: controlColor,
                        animatesPlaceholder: isThisPlaying
                    )
                    .frame(height: 22)
                }
            }

            Group {
                if hasPlaybackPosition {
                    let elapsed = Int(Double(duration) * voiceManager.playbackProgress)
                    Text(formatDuration(elapsed))
                        .foregroundStyle(WristTheme.Palette.primaryText)
                } else {
                    Text(formatDuration(duration))
                        .foregroundStyle(secondaryColor)
                }
            }
            .font(.system(size: AppConstants.UI.FontSize.small).monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .contentShape(Rectangle())
        .onTapGesture { togglePlayback() }
        .accessibilityLabel(isThisPlaying ? L10n.string("Pause voice message") : L10n.string("Play voice message"))
        .accessibilityValue(isLoading ? L10n.string("Loading") : (loadFailed ? L10n.string("Tap to retry") : ""))
        .onChange(of: playbackRequest) { _, _ in
            togglePlayback()
        }
        .task(id: LoadRequest(fileId: fileId, downloadRequests: downloadRequests)) {
            await loadAudio(for: fileId, downloadRequests: downloadRequests)
        }
        .onDisappear {
            playsOnceHeldFileIsFound = false
            cancelPendingPlayback()
        }
    }

    private func loadAudio(for requestedFileId: String, downloadRequests: Int) async {
        audioData = nil
        loadFailed = false
        isLookingForHeldFile = false
        playsOnceHeldFileIsFound = false
        guard hasValidFileId else {
            isLoading = false
            loadFailed = true
            cancelPendingPlayback()
            return
        }
        guard downloadRequests > 0 else {
            // Not asked for yet. A file the transport already holds, one the
            // user sent or played before, is ready to play without a wait.
            isLoading = false
            isLookingForHeldFile = true
            let held = await imageCache.cachedData(fileId: requestedFileId)
            guard !Task.isCancelled, requestedFileId == fileId else { return }
            isLookingForHeldFile = false
            audioData = held
            guard playsOnceHeldFileIsFound else { return }
            playsOnceHeldFileIsFound = false
            if let held {
                startPlayback(held, allowRefresh: true)
            } else {
                requestReload()
            }
            return
        }
        // The first request downloads; later ones are retries after a failure
        // and load past what the earlier try left behind.
        let refresh = downloadRequests > 1
        isLoading = true
        let data = if refresh {
            await imageCache.reloadData(fileId: requestedFileId, priority: downloadPriority, requester: requester)
        } else {
            await imageCache.loadData(fileId: requestedFileId, priority: downloadPriority, requester: requester)
        }
        guard !Task.isCancelled, requestedFileId == fileId else { return }
        isLoading = false
        if let data {
            audioData = data
            if let requestID = pendingPlaybackRequest,
               voiceManager.consumePlaybackRequest(requestID) {
                pendingPlaybackRequest = nil
                startPlayback(data, allowRefresh: !refresh)
            }
        } else {
            loadFailed = true
            cancelPendingPlayback()
        }
    }

    private func togglePlayback() {
        guard hasValidFileId else {
            loadFailed = true
            return
        }
        if isThisPlaying {
            voiceManager.pause()
        } else if voiceManager.isPaused(fileId: fileId) {
            if !voiceManager.resume() { requestReload() }
        } else if isLoading {
            if let requestID = pendingPlaybackRequest,
               voiceManager.isPlaybackRequestCurrent(requestID) {
                cancelPendingPlayback()
            } else {
                pendingPlaybackRequest = voiceManager.requestPlayback()
                // Played before it arrived: the user waits for this one.
                imageCache.setPriority(.requested, fileId: fileId, requester: requester)
            }
        } else if let data = audioData {
            startPlayback(data, allowRefresh: true)
        } else if isLookingForHeldFile {
            // The file may be on the device already; a second tap takes the
            // request back, as it does for a download.
            playsOnceHeldFileIsFound.toggle()
        } else {
            requestReload()
        }
    }

    private func requestReload() {
        isLoading = true
        loadFailed = false
        pendingPlaybackRequest = voiceManager.requestPlayback()
        downloadRequests += 1
    }

    private func cancelPendingPlayback() {
        if let requestID = pendingPlaybackRequest {
            voiceManager.cancelPlaybackRequest(requestID)
            pendingPlaybackRequest = nil
            // Nobody waits for it to play, but the download goes on.
            imageCache.setPriority(.onScreen, fileId: fileId, requester: requester)
        }
    }

    private func startPlayback(_ data: Data, allowRefresh: Bool) {
        if voiceManager.play(data: data, fileId: fileId) {
            notifyMessageContentOpened()
        } else if allowRefresh {
            requestReload()
        } else {
            imageCache.invalidate(fileId: fileId)
            audioData = nil
            loadFailed = true
        }
    }

    private func notifyMessageContentOpened() {
        guard let chatId, let messageId else { return }
        let service = chatRepository.service
        Task { await service.openMessageContent(chatId: chatId, messageId: messageId) }
    }

    /// Ahead of everything else while the user waits to hear it.
    private var downloadPriority: DownloadPriority {
        pendingPlaybackRequest == nil ? .onScreen : .requested
    }

    private func formatDuration(_ seconds: Int) -> String {
        TimeFormatting.duration(seconds)
    }
}
