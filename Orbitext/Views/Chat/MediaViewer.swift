import os
import SwiftUI

enum MediaViewerMode: Hashable {
    case photo
    case video

    /// A video fills the screen, so the viewer hides the system navigation bar.
    var hidesNavigationBar: Bool { self == .video }

    /// Without the system bar there is no way out, so the viewer draws one.
    var drawsOwnBackButton: Bool { self == .video }
}

struct MediaViewer: View {
    @Environment(ImageCache.self) private var imageCache
    @Environment(\.dismiss) private var dismiss
    let fileId: String
    var mode: MediaViewerMode = .photo
    var title = "Photo"
    /// Whether this viewer is the currently visible page in an album
    /// gallery. Forwarded to ZoomablePhotoView so Digital Crown focus
    /// stays on the photo the user actually sees.
    var isActive = true
    /// Whether the page keeps its decoded photo while it is not the one on
    /// screen. An album gallery builds a viewer for every photo and lets the
    /// pages far from the selected one go, or each page shown would hold a
    /// full bitmap until the gallery closes.
    var keepsImage = true
    /// A smaller file of the same photo, which the chat already drew. It
    /// stands in while the full-size file downloads.
    var previewFileId: String?

    @State private var image: UIImage?
    /// The file `image` was loaded from.
    @State private var loadedFileId: String?
    @State private var previewImage: UIImage?
    /// The file `previewImage` was loaded from.
    @State private var loadedPreviewFileId: String?
    @State private var scale: CGFloat = 1.0
    @State private var loadFailed = false
    @State private var isLoading = true
    @State private var attempt = 0
    /// The last retry that has invalidated the cache. A page paged back to
    /// loads past what is left behind only for a retry it has not run yet.
    @State private var invalidatedAttempt = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            WristTheme.Palette.canvas.ignoresSafeArea()

            switch mode {
            case .photo:
                photoContent
            case .video:
                VideoPlayerView(fileId: fileId)
            }

            if mode.drawsOwnBackButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background { WristGlassBackground(cornerRadius: 22) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.top, 4)
                .padding(.leading, 2)
                .accessibilityLabel(L10n.string("Back"))
            }
        }
        // Video mode draws its own overlay back button above the movie
        // surface. Hiding the navigation title + toolbar avoids duplicated
        // chrome while loading and while the movie is visible.
        .navigationTitle(mode == .video ? "" : title)
        .toolbar(mode.hidesNavigationBar ? .hidden : .automatic, for: .navigationBar)
        // An album gallery builds every page at once; only the page on screen
        // downloads its photo, and the others wait to be swiped to.
        .task(id: MediaLoadID(fileId: "\(mode)-\(fileId)", attempt: attempt, isWanted: isActive)) {
            // The page shows its photo already when it is paged back to.
            guard mode == .photo, isActive, image == nil || loadedFileId != fileId else { return }
            await loadPhoto(forceReload: attempt > invalidatedAttempt)
        }
        // The preview is the page's own, so it waits like the photo does: the
        // mosaic draws only the first four cells, and the previews of the
        // other pages would otherwise queue ahead of the photo on screen.
        .task(id: MediaLoadID(fileId: previewFileId ?? "", isWanted: isActive)) {
            await loadPreview()
        }
        .onChange(of: keepsImage) { _, keeps in
            guard !keeps else { return }
            releasePhoto()
        }
    }

    // MARK: - Photo Content

    @ViewBuilder
    private var photoContent: some View {
        if let image {
            ZoomablePhotoView(image: image, scale: $scale, isActive: isActive)
        } else if loadFailed {
            MediaRetryButton(mode: .photo) {
                // The retry is the task's, so leaving the viewer ends its download.
                loadFailed = false
                attempt += 1
            }
        } else if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .overlay { ProgressView() }
        } else {
            ProgressView()
        }
    }

    // MARK: - Photo Loading

    /// The small file the chat showed: ready at once from memory, so the
    /// viewer opens on the photo and sharpens when the full-size file lands.
    ///
    /// The preview stays when the page stops being the one on screen, even
    /// after the page let go of its photo: it is about 240 px, under 0.5 MB,
    /// and it is what a page seen before draws while it is dragged in.
    private func loadPreview() async {
        guard mode == .photo, let previewFileId, !previewFileId.isEmpty, previewFileId != "0" else {
            previewImage = nil
            loadedPreviewFileId = nil
            return
        }
        if loadedPreviewFileId != previewFileId {
            previewImage = nil
            loadedPreviewFileId = nil
        }
        guard isActive, previewImage == nil else { return }
        let loaded = await imageCache.load(fileId: previewFileId, priority: .requested)
        guard !Task.isCancelled else { return }
        previewImage = loaded
        loadedPreviewFileId = loaded == nil ? nil : previewFileId
    }

    /// The page comes back to a photo it loads again, as on its first visit:
    /// fitted to the screen, with the preview in its place meanwhile.
    private func releasePhoto() {
        image = nil
        loadedFileId = nil
        scale = 1.0
    }

    private func loadPhoto(forceReload: Bool = false) async {
        isLoading = true
        loadFailed = false

        if forceReload {
            invalidatedAttempt = attempt
            imageCache.invalidate(fileId: fileId)
        }
        // Use full-resolution for viewer (not downsampled thumbnail)
        let loaded = await imageCache.loadFullSize(fileId: fileId)
        // A page swiped away stops its download; that is not a failure.
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            loadedFileId = fileId
        } else {
            loadFailed = true
        }
        isLoading = false
    }
}
