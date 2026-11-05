import SwiftUI

private struct MediaThumbnailShape: Shape {
    let style: VideoThumbnailView.Style

    func path(in rect: CGRect) -> Path {
        switch style {
        case .video:
            return RoundedRectangle(cornerRadius: AppConstants.UI.Bubble.cornerRadius).path(in: rect)
        case .videoNote:
            return Circle().path(in: rect)
        }
    }
}

struct VideoThumbnailView: View {
    enum Style {
        case video
        case videoNote
    }

    @Environment(ImageCache.self) private var imageCache
    @Environment(\.isMediaWanted) private var isMediaWanted
    let fileId: String
    let thumbnailId: String?
    let width: Int
    let height: Int
    let duration: Int
    let style: Style
    var minithumbnail: Data?

    @State private var image: UIImage?
    /// The file `image` was loaded from.
    @State private var loadedFileId: String?
    @State private var loadFailed = false
    @State private var showFallbackViewer = false

    private var hasValidFileId: Bool {
        !fileId.isEmpty && fileId != "0"
    }

    private var hasThumbnail: Bool {
        guard let thumbnailId else { return false }
        return !thumbnailId.isEmpty && thumbnailId != "0"
    }

    private var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return CGFloat(width) / CGFloat(height)
    }

    private var thumbnailHeight: CGFloat {
        switch style {
        case .videoNote:
            return AppConstants.UI.Thumbnail.videoNoteSize
        case .video:
            let computedHeight = AppConstants.UI.Thumbnail.maxWidth / aspectRatio
            return min(max(computedHeight, AppConstants.UI.Thumbnail.minHeight), AppConstants.UI.Thumbnail.maxHeight)
        }
    }

    private var thumbnailWidth: CGFloat {
        // Constrain the image before clipping: a panoramic poster must not
        // report its aspect-ratio width as the minimum width of the chat.
        style == .videoNote ? thumbnailHeight : AppConstants.UI.Thumbnail.maxWidth
    }

    var body: some View {
        Group {
            if hasValidFileId {
                Button {
                    showFallbackViewer = true
                } label: {
                    thumbnailBody
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style == .video ? L10n.string("Open video") : L10n.string("Open video message"))
                .sheet(isPresented: $showFallbackViewer) {
                    MediaViewer(fileId: fileId, mode: .video, title: style == .video ? L10n.string("Video") : L10n.string("Video message"))
                }
            } else {
                thumbnailBody
            }
        }
        // Loads the poster while the row is on screen; see `isMediaWanted`.
        .task(id: MediaLoadID(fileId: thumbnailId ?? "", isWanted: isMediaWanted)) {
            await loadThumbnail()
        }
    }

    private var thumbnailBody: some View {
        ZStack {
            thumbnailBackground
            thumbnailOverlay
        }
        .contentShape(MediaThumbnailShape(style: style))
    }

    @ViewBuilder
    private var thumbnailBackground: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                .clipShape(MediaThumbnailShape(style: style))
        } else if let mini = minithumbnail, let placeholder = UIImage(data: mini) {
            // TDLib minithumbnail bytes -> blurred placeholder while the
            // real video poster downloads. Same radius as TDLibImage so
            // single photos and video posters feel visually consistent.
            Image(uiImage: placeholder)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                .clipShape(MediaThumbnailShape(style: style))
                .blur(radius: 8)
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: AppConstants.UI.Bubble.cornerRadius)
            .fill(WristTheme.Palette.mutedSurface)
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipShape(MediaThumbnailShape(style: style))
            .overlay {
                Image(systemName: style == .video ? "video.fill" : "video.circle.fill")
                    .font(.title3)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
            }
    }

    private var thumbnailOverlay: some View {
        ZStack {
            if loadFailed && hasThumbnail {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .accessibilityLabel(L10n.string("Retry media"))
            } else {
                Image(systemName: "play.circle.fill")
                    .font(style == .video ? .title : .system(size: 28))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .accessibilityLabel(L10n.string("Play video"))
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(TimeFormatting.duration(duration))
                        .font(.system(size: AppConstants.UI.FontSize.tiny).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(6)
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
    }

    private func loadThumbnail() async {
        guard hasThumbnail, let thumbnailId else { return }
        // A poster already drawn stays while its row is away.
        if loadedFileId != thumbnailId {
            image = nil
            loadedFileId = nil
        }
        loadFailed = false
        guard isMediaWanted, image == nil else { return }
        let loaded = await imageCache.load(fileId: thumbnailId)
        // A row scrolled away stops its download; that is not a failure.
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            loadedFileId = thumbnailId
        } else {
            loadFailed = true
        }
    }
}
