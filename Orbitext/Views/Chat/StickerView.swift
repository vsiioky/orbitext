import SwiftUI

struct StickerView: View {
    @Environment(ImageCache.self) private var imageCache
    @Environment(\.isMediaWanted) private var isMediaWanted
    @Environment(\.displayScale) private var displayScale
    let emoji: String
    let fileId: String
    let thumbnailFileId: String?

    @State private var animation = StickerAnimation()
    @State private var thumbnailImage: UIImage?
    /// The sticker `thumbnailImage` shows.
    @State private var loadedFileId: String?
    @State private var isLoadingThumbnail = false
    @State private var isRenderingFrames = false
    @State private var animationTimer: Timer?
    @State private var renderTask: Task<[UIImage], Never>?
    @State private var frameLoadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let frame = animation.frame {
                // Playing animation
                Image(uiImage: frame)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else if let thumbnailImage {
                // Static thumbnail - tap to animate
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if isRenderingFrames {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            } else if isLoadingThumbnail {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(emoji)
                    .font(.largeTitle)
            }
        }
        // One slot whatever the sticker shows. A timeline row released off
        // screen keeps the height it measured and is drawn again from the
        // emoji up when it comes back; a sticker that changed size on the
        // way would move the rows around it.
        .frame(width: AppConstants.UI.Sticker.size, height: AppConstants.UI.Sticker.size)
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap()
        }
        .accessibilityLabel(animation.isPlaying ? L10n.string("Stop sticker animation") : "\(emoji) \(L10n.string("Sticker"))")
        // Loads while the row is on screen; see `isMediaWanted`. A sticker
        // whose row was scrolled away keeps the picture it has.
        .task(id: MediaLoadID(fileId: fileId, isWanted: isMediaWanted)) {
            if loadedFileId != fileId { resetState() }
            guard isMediaWanted, thumbnailImage == nil else { return }
            await loadThumbnail()
        }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
            frameLoadTask?.cancel()
            frameLoadTask = nil
            stopAnimation()
        }
    }

    /// The picture is decoded to the pixels of the slot it is drawn in.
    private var pictureSize: CGFloat {
        AppConstants.UI.Sticker.size * displayScale
    }

    private func resetState() {
        renderTask?.cancel()
        renderTask = nil
        frameLoadTask?.cancel()
        frameLoadTask = nil
        stopAnimation()
        thumbnailImage = nil
        loadedFileId = nil
        isLoadingThumbnail = false
        isRenderingFrames = false
    }

    /// The thumbnail comes from the shared cache, decoded to the size it is
    /// drawn at and counted in the cache's budget, so every row of the
    /// sticker shares one bitmap and a row drawn again finds it there.
    private func loadThumbnail() async {
        isLoadingThumbnail = true
        defer { isLoadingThumbnail = false }
        if let thumbnailFileId {
            thumbnailImage = await imageCache.load(fileId: thumbnailFileId, maxDimension: pictureSize)
        }
        // A row scrolled away stops its download.
        guard !Task.isCancelled else { return }
        if thumbnailImage == nil {
            thumbnailImage = await loadStickerFilePicture()
        }
        if thumbnailImage != nil, !Task.isCancelled { loadedFileId = fileId }
    }

    /// The sticker file stands in for a thumbnail that is missing. When a
    /// thumbnail was advertised but failed, the file is used only if it is on
    /// the watch already, from a previous tap; it is not downloaded for this.
    private func loadStickerFilePicture() async -> UIImage? {
        if thumbnailFileId != nil {
            guard await imageCache.cachedData(fileId: fileId) != nil, !Task.isCancelled else { return nil }
        }
        // A static sticker (WEBP) decodes like any picture.
        if let picture = await imageCache.load(fileId: fileId, maxDimension: pictureSize) {
            return picture
        }
        // An animated one (TGS) is no picture: its first frame stands in.
        // The file is on the watch by now.
        guard !Task.isCancelled, let stickerData = await imageCache.cachedData(fileId: fileId) else { return nil }
        return await Task.detached(priority: .utility) {
            // The renderer stays on the task that made it; only the image leaves.
            LottieRenderer(tgsData: stickerData, width: 64, height: 64)?.renderFrame(at: 0)
        }.value
    }

    /// The frames of the animation, rendered for this play.
    private func renderFrames() async -> [UIImage] {
        isRenderingFrames = true
        defer { isRenderingFrames = false }
        // The user tapped the sticker to play it.
        guard let stickerData = await imageCache.loadData(fileId: fileId, priority: .requested),
              !Task.isCancelled else { return [] }
        let task = Task.detached(priority: .utility) {
            guard let renderer = LottieRenderer(tgsData: stickerData, width: 64, height: 64) else {
                return [UIImage]()
            }
            let step = max(1, Int(renderer.frameRate / 15))
            let maxFrames = 75 // Cap to prevent memory spikes on watch
            var rendered = renderer.renderFrames(step: step, cancel: { Task.isCancelled })
            if rendered.count > maxFrames {
                rendered = Array(rendered.prefix(maxFrames))
            }
            return rendered
        }
        renderTask = task
        let rendered = await task.value
        renderTask = nil
        return Task.isCancelled ? [] : rendered
    }

    private func handleTap() {
        if animation.isPlaying {
            stopAnimation()
            return
        }
        guard frameLoadTask == nil else { return }
        frameLoadTask = Task {
            let frames = await renderFrames()
            if !Task.isCancelled, !frames.isEmpty {
                playOnce(frames)
            }
            frameLoadTask = nil
        }
    }

    private func playOnce(_ frames: [UIImage]) {
        animation.play(frames)
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            Task { @MainActor in
                animation.advance()
                if !animation.isPlaying {
                    // Animation complete - stop
                    stopAnimation()
                }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animation.stop()
    }
}

/// The frames of a sticker that plays, for as long as it plays.
///
/// A tap renders up to 75 frames of 64 px, each a bitmap with its own 16 KB
/// buffer: 0.7-1.2 MB a sticker. A played sticker kept them until its row
/// was gone; a replay renders them again, in tens of milliseconds off the
/// main actor.
struct StickerAnimation {
    private var frames: [UIImage] = []
    private var currentFrame = 0

    var isPlaying: Bool { !frames.isEmpty }

    /// The frame on screen; nil when the sticker does not play.
    var frame: UIImage? { frames.isEmpty ? nil : frames[currentFrame] }

    mutating func play(_ frames: [UIImage]) {
        self.frames = frames
        currentFrame = 0
    }

    /// Moves to the next frame. After the last one the animation is over and
    /// lets its frames go.
    mutating func advance() {
        let next = currentFrame + 1
        if next < frames.count {
            currentFrame = next
        } else {
            stop()
        }
    }

    mutating func stop() {
        frames = []
        currentFrame = 0
    }
}
