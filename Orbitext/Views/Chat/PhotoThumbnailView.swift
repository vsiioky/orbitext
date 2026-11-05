import SwiftUI

struct PhotoThumbnailView: View {
    @Environment(ImageCache.self) private var imageCache
    @Environment(\.isMediaWanted) private var isMediaWanted
    let fileId: String
    let width: Int
    let height: Int
    var minithumbnail: Data?
    /// A smaller file of the same photo, drawn in the chat. `fileId` is the
    /// full-size file, which only the viewer needs.
    var previewFileId: String?

    @State private var image: UIImage?
    /// The file `image` was loaded from.
    @State private var loadedFileId: String?
    @State private var loadFailed = false
    @State private var showViewer = false

    private var hasValidFileId: Bool {
        !fileId.isEmpty && fileId != "0"
    }

    /// The file the tile draws: the preview when the photo has one.
    private var tileFileId: String {
        if let previewFileId, !previewFileId.isEmpty, previewFileId != "0" { return previewFileId }
        return fileId
    }

    private var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return CGFloat(width) / CGFloat(height)
    }

    private var thumbnailHeight: CGFloat {
        let computedHeight = AppConstants.UI.Thumbnail.maxWidth / aspectRatio
        return min(max(computedHeight, AppConstants.UI.Thumbnail.minHeight), AppConstants.UI.Thumbnail.maxHeight)
    }

    var body: some View {
        Group {
            if hasValidFileId {
                Button {
                    showViewer = true
                } label: {
                    thumbnailBody
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Open photo"))
                .sheet(isPresented: $showViewer) {
                    MediaViewer(fileId: fileId, mode: .photo, title: L10n.string("Photo"), previewFileId: previewFileId)
                }
            } else {
                thumbnailBody
            }
        }
        // Loads while the row is on screen. Scrolling it away cancels the
        // task and with it a download in progress; scrolling back starts it
        // again, which is also the second try after a failure.
        .task(id: MediaLoadID(fileId: tileFileId, isWanted: isMediaWanted)) {
            await loadThumbnail()
        }
    }

    private var thumbnailBody: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: AppConstants.UI.Thumbnail.maxWidth, height: thumbnailHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius))
            } else if loadFailed {
                RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius)
                    .fill(WristTheme.Palette.mutedSurface)
                    .frame(width: AppConstants.UI.Thumbnail.maxWidth, height: thumbnailHeight)
                    .overlay {
                        VStack(spacing: 2) {
                            Image(systemName: "photo")
                                .font(.caption)
                            if !hasValidFileId {
                                Text(L10n.string("Tap to retry"))
                                    .font(.system(size: AppConstants.UI.FontSize.tiny))
                            }
                        }
                        .foregroundStyle(WristTheme.Palette.secondaryText)
                    }
            } else if let mini = minithumbnail, let placeholder = UIImage(data: mini) {
                // TDLib minithumbnail (8-byte InlineQueryResultPhoto-style
                // JPEG, max 40x40) - render blurred so the bubble has
                // immediate visual feedback while the real file streams
                // in from network.
                Image(uiImage: placeholder)
                    .resizable()
                    .scaledToFill()
                    .frame(width: AppConstants.UI.Thumbnail.maxWidth, height: thumbnailHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius))
                    .blur(radius: 8)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
            } else {
                RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius)
                    .fill(WristTheme.Palette.mutedSurface)
                    .frame(width: AppConstants.UI.Thumbnail.maxWidth, height: thumbnailHeight)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
            }
        }
        // Clipping the image alone leaves its original, oversized hit region.
        // Keep the photo button and its accessibility bounds on the thumbnail.
        .contentShape(RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius))
    }

    private func loadThumbnail() async {
        let fileId = tileFileId
        // A picture already drawn stays while its row is away.
        if loadedFileId != fileId {
            image = nil
            loadedFileId = nil
        }
        loadFailed = false
        guard isMediaWanted, image == nil else { return }
        let loaded = await imageCache.load(fileId: fileId)
        // A row scrolled away stops its download; that is not a failure.
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            loadedFileId = fileId
        } else {
            loadFailed = true
        }
    }
}
