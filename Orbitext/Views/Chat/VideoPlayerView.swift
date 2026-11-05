import AVFoundation
import os
import SwiftUI
import WatchKit

private struct WatchInlineMoviePlayerView: WKInterfaceObjectRepresentable {
    let url: URL

    func makeCoordinator() -> InlineMovieLoader {
        InlineMovieLoader()
    }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceInlineMovie {
        let movie = WKInterfaceInlineMovie()
        context.coordinator.show(url, in: movie)
        return movie
    }

    func updateWKInterfaceObject(_ movie: WKInterfaceInlineMovie, context: Context) {
        context.coordinator.show(url, in: movie)
    }

    static func dismantleWKInterfaceObject(_ movie: WKInterfaceInlineMovie, coordinator: InlineMovieLoader) {
        coordinator.close(movie)
    }
}

struct VideoPlayerView: View {
    let fileId: String
    @Environment(ImageCache.self) private var imageCache
    @State private var videoURL: URL?
    @State private var loadFailed = false
    @State private var isLoading = true
    @State private var attempt = 0

    var body: some View {
        Group {
            if let videoURL {
                WatchInlineMoviePlayerView(url: videoURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                MediaRetryButton(
                    mode: .video,
                    message: L10n.string("Video could not be opened"),
                    actionTitle: L10n.string("Retry")
                ) {
                    // The retry is the task's, so leaving the player ends its download.
                    loadFailed = false
                    attempt += 1
                }
            } else {
                ProgressView()
            }
        }
        .task(id: MediaLoadID(fileId: fileId, attempt: attempt)) {
            await loadVideo(forceReload: attempt > 0)
        }
        .onDisappear {
            removeVideoFile()
            // The copy the player read; the next open makes a new one.
            imageCache.removeSharedPlaybackFile(fileId: fileId)
        }
    }

    // MARK: - Loading

    private func loadVideo(forceReload: Bool = false) async {
        isLoading = true
        loadFailed = false

        let playbackURL = forceReload
            ? await imageCache.reloadSharedPlaybackFile(fileId: fileId)
            : await imageCache.loadSharedPlaybackFile(fileId: fileId)

        guard let playbackURL else {
            Logger.app.error("Failed to resolve video file for fileId=\(fileId, privacy: .public)")
            loadFailed = true
            isLoading = false
            return
        }

        removeVideoFile()
        videoURL = playbackURL

        let asset = AVURLAsset(url: playbackURL)
        await logVideoPreflight(for: playbackURL, asset: asset)

        isLoading = false
    }

    private func logVideoPreflight(for playbackURL: URL, asset: AVURLAsset) async {
        let fileSize = (try? playbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let duration = await (try? asset.load(.duration).seconds) ?? 0
        let tracks = await (try? asset.load(.tracks)) ?? []
        let audioTracks = tracks.filter { $0.mediaType == .audio }.count
        let videoTracks = tracks.filter { $0.mediaType == .video }.count

        Logger.app.debug(
            "Preparing WatchKit video fileId=\(fileId, privacy: .public), ext=\(playbackURL.pathExtension, privacy: .public), size=\(fileSize, privacy: .public), duration=\(duration, privacy: .public), audioTracks=\(audioTracks, privacy: .public), videoTracks=\(videoTracks, privacy: .public)"
        )
    }

    // MARK: - Cleanup

    private func removeVideoFile() {
        guard let videoURL else { return }
        // Only remove temporary files, not shared playback directory files
        let tempDir = FileManager.default.temporaryDirectory.path
        if videoURL.path.hasPrefix(tempDir) {
            try? FileManager.default.removeItem(at: videoURL)
        }
        self.videoURL = nil
    }
}

/// What the player asks of WatchKit's inline movie, so a test can stand in
/// for it.
@MainActor
protocol InlineMovie: AnyObject {
    func setMovieURL(_ url: URL)
    func setVideoGravity(_ videoGravity: WKVideoGravity)
    func setLoops(_ loops: Bool)
    func setAutoplays(_ autoplays: Bool)
    func play()
    func pause()
}

extension WKInterfaceInlineMovie: InlineMovie {}

/// Gives the inline movie its file once. SwiftUI updates the representable
/// whenever its environment changes (the scene going inactive at
/// wrist-down, reduced luminance, the presenting row's media flag), and a
/// movie given its URL again started over at 0:00 with a new player item.
@MainActor
final class InlineMovieLoader {
    private var loadedURL: URL?

    func show(_ url: URL, in movie: some InlineMovie) {
        guard url != loadedURL else { return }
        loadedURL = url
        movie.setMovieURL(url)
        movie.setVideoGravity(.resizeAspect)
        movie.setLoops(false)
        movie.setAutoplays(true)
        movie.play()
    }

    /// The player is gone: the sound stops with it.
    func close(_ movie: some InlineMovie) {
        movie.pause()
        loadedURL = nil
    }
}
