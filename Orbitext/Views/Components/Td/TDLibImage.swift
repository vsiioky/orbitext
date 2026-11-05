import SwiftUI

/// Async image view backed by TDLib + ImageCache (memory -> disk -> network).
///
/// Differences from a naive per-view download task:
/// - Pulls from the project-wide `ImageCache` 3-tier pipeline rather than a
///   per-view download task, so concurrent views for the same fileId share
///   one in-flight fetch.
/// - Uses `@Environment(ImageCache.self)` (Observation) instead of an
///   EnvironmentObject.
/// - Watch-friendly: optional `thumbnailData` (TDLib minithumbnail bytes)
///   renders a blurred placeholder while the full image downloads.
struct TDLibImage<Placeholder: View>: View {
    let fileId: String
    var thumbnailData: Data?
    var contentMode: ContentMode = .fill
    /// Optional dimension cap for the decoded UIImage. When set, the
    /// loaded bitmap is downsampled so neither edge exceeds this many
    /// points - critical for mosaic / multi-cell layouts on watchOS
    /// where six full-size photos can blow the per-app RAM budget.
    /// `nil` (default) preserves the original behaviour: shared 240pt
    /// memory-cache bucket via `ImageCache.load(fileId:)`.
    var maxDimension: CGFloat?
    /// Avatars keep their initials as the loading/error fallback.
    var showsStatusOverlays = true
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(ImageCache.self) private var imageCache
    @Environment(\.isMediaWanted) private var isMediaWanted
    @State private var image: UIImage?
    /// The file `image` was loaded from.
    @State private var loadedFileId: String?
    @State private var loadFailed = false

    private var hasValidFileId: Bool {
        !fileId.isEmpty && fileId != "0"
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let thumb = thumbnailData, let placeholderImage = UIImage(data: thumb) {
                Image(uiImage: placeholderImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .blur(radius: 8)
                    .overlay(loadingOverlay)
            } else if loadFailed {
                placeholder()
                    .overlay {
                        if showsStatusOverlays {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(WristTheme.Palette.secondaryText)
                        }
                    }
            } else {
                placeholder()
                    .overlay(loadingOverlay)
            }
        }
        // Loads while the view is wanted; see `isMediaWanted`.
        .task(id: MediaLoadID(fileId: fileId, isWanted: isMediaWanted)) {
            await load()
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if showsStatusOverlays && image == nil && !loadFailed {
            ProgressView()
                .scaleEffect(0.6)
        }
    }

    private func load() async {
        let requestedFileId = fileId
        // A picture already drawn stays while its row is away.
        if loadedFileId != requestedFileId {
            image = nil
            loadedFileId = nil
        }
        loadFailed = false
        guard hasValidFileId else {
            loadFailed = true
            return
        }
        guard isMediaWanted, image == nil else { return }
        let loaded: UIImage?
        if let maxDimension {
            loaded = await imageCache.load(fileId: requestedFileId, maxDimension: maxDimension)
        } else {
            loaded = await imageCache.load(fileId: requestedFileId)
        }
        // Guard against late completion after the view was reused for a
        // different fileId, or its row was scrolled away.
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            loadedFileId = requestedFileId
        } else {
            loadFailed = true
        }
    }
}

extension TDLibImage where Placeholder == TDLibImageDefaultPlaceholder {
    init(
        fileId: String,
        thumbnailData: Data? = nil,
        contentMode: ContentMode = .fill,
        maxDimension: CGFloat? = nil
    ) {
        self.init(
            fileId: fileId,
            thumbnailData: thumbnailData,
            contentMode: contentMode,
            maxDimension: maxDimension,
            placeholder: { TDLibImageDefaultPlaceholder() }
        )
    }
}

struct TDLibImageDefaultPlaceholder: View {
    var body: some View {
        Rectangle()
            .fill(WristTheme.Palette.mutedSurface)
    }
}

#if DEBUG
/// A transport without files: the previews show their placeholders.
private final class PreviewFileAccess: TelegramFileAccess {
    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        throw TelegramServiceError.downloadFailed
    }
}

@MainActor
private func makePreviewImageCache() -> ImageCache {
    ImageCache(service: PreviewFileAccess())
}

#Preview("TDLibImage - default placeholder") {
    TDLibImage(fileId: "0")
        .frame(width: 120, height: 90)
        .environment(makePreviewImageCache())
}

#Preview("TDLibImage - downsampled 64pt") {
    TDLibImage(fileId: "0", maxDimension: 64)
        .frame(width: 64, height: 64)
        .clipped()
        .environment(makePreviewImageCache())
}

#Preview("TDLibImage - custom placeholder") {
    TDLibImage(
        fileId: "0",
        contentMode: .fit,
        placeholder: {
            RoundedRectangle(cornerRadius: 8)
                .fill(WristTheme.Palette.canvas)
        }
    )
    .frame(width: 120, height: 90)
    .environment(makePreviewImageCache())
}
#endif
