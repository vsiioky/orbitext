import SwiftUI

/// Mosaic-style rendering of a TDLib media album inside a message
/// bubble. Up to four thumbnails are visible at once; any further
/// items are folded under a "+N" overlay on the last visible cell.
/// Tapping anywhere on the mosaic opens `AlbumGalleryView` which
/// pages through the originals at full size.
struct AlbumView: View {
    let album: MessageAlbumInfo
    let isGroup: Bool
    let availableWidth: CGFloat
    var onReply: (() -> Void)?
    var onForward: ((MessageInfo) -> Void)?

    @State private var galleryStartIndex: Int? = nil

    /// Reserve the opposite-side gutter, bubble padding and tail before
    /// sizing the mosaic. A fixed 150pt album exceeds a 40mm watch row.
    private var mosaicWidth: CGFloat {
        let insets = AppConstants.UI.messageRowInsets
        let contentWidth = availableWidth - insets.leading - insets.trailing
            - AppConstants.UI.Bubble.spacerMinLength
            - 2 * AppConstants.UI.Bubble.horizontalPadding
            - MessageBubbleShape.tailExtent
        return min(AppConstants.UI.Thumbnail.maxWidth + 30, max(2, contentWidth))
    }

    /// Number of cells we visually expose. Anything beyond becomes a
    /// "+N" overlay on the final visible thumbnail.
    private let maxVisible = 4

    var body: some View {
        HStack(spacing: 0) {
            if album.isOutgoing { Spacer(minLength: AppConstants.UI.Bubble.spacerMinLength) }

            bubble

            if !album.isOutgoing { Spacer(minLength: AppConstants.UI.Bubble.spacerMinLength) }
        }
        .sheet(item: Binding(
            get: { galleryStartIndex.map { GalleryStart(index: $0) } },
            set: { galleryStartIndex = $0?.index }
        )) { start in
            AlbumGalleryView(album: album, startIndex: start.index)
        }
    }

    private var bubble: some View {
        VStack(alignment: album.isOutgoing ? .trailing : .leading, spacing: 4) {
            if isGroup && !album.isOutgoing {
                Text(album.senderName)
                    .font(.system(size: AppConstants.UI.FontSize.small, weight: .semibold))
                    .foregroundStyle(WristTheme.Palette.warning)
            }

            mosaic

            if let caption = album.caption, !caption.isEmpty {
                MessageTextView(formatted: caption, isOutgoing: album.isOutgoing)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: mosaicWidth, alignment: .leading)
            }

            HStack(spacing: 2) {
                Text(album.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: AppConstants.UI.FontSize.tiny))
                    .foregroundStyle(album.isOutgoing ? .white.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, AppConstants.UI.Bubble.horizontalPadding)
        .padding(.vertical, AppConstants.UI.Bubble.verticalPadding)
        .padding(album.isOutgoing ? .trailing : .leading, MessageBubbleShape.tailExtent)
        .background { WristBubbleBackground(isOutgoing: album.isOutgoing) }
        .onLongPressGesture {
            onReply?()
            HapticManager.tap()
        }
    }

    // MARK: - Mosaic

    private var mosaic: some View {
        let thumbs = album.thumbnails
        let visible = Array(thumbs.prefix(maxVisible))
        let hiddenCount = max(0, thumbs.count - visible.count)
        let cellSide = (mosaicWidth - 2) / 2 // 2pt inner gutter

        return VStack(spacing: 2) {
            ForEach(rows(of: visible), id: \.self) { rowIndices in
                HStack(spacing: 2) {
                    ForEach(rowIndices, id: \.self) { cellIndex in
                        cell(
                            for: visible[cellIndex],
                            side: cellSide,
                            overlayCount: cellIndex == visible.count - 1 ? hiddenCount : 0
                        )
                    }
                }
            }
        }
        .frame(width: mosaicWidth)
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.Thumbnail.cornerRadius))
    }

    /// Pair up the visible thumbnails into two-column rows. The last
    /// row may be a single cell when the count is odd; we stretch it
    /// to the full mosaic width so the layout never looks "missing
    /// a corner".
    private func rows(of visible: [AlbumThumbnail]) -> [[Int]] {
        var rows: [[Int]] = []
        var i = 0
        while i < visible.count {
            if i + 1 < visible.count {
                rows.append([i, i + 1])
                i += 2
            } else {
                rows.append([i])
                i += 1
            }
        }
        return rows
    }

    private func cell(for thumb: AlbumThumbnail, side: CGFloat, overlayCount: Int) -> some View {
        Button {
            if let idx = album.thumbnails.firstIndex(of: thumb) {
                galleryStartIndex = idx
            }
        } label: {
            ZStack {
                TDLibImage(
                    fileId: thumb.previewFileId ?? thumb.fileId,
                    thumbnailData: thumb.minithumbnail,
                    contentMode: .fill,
                    // maxDimension is in points (ImageCache.downsample
                    // clamps UIImage.size, which is in points). Passing
                    // side * screenScale here would oversample by 2x and
                    // burn ~4x the RAM for no visual gain - UIImage's
                    // own scale handling already preserves retina sharpness.
                    maxDimension: side
                ) {
                    Rectangle()
                        .fill(WristTheme.Palette.mutedSurface)
                }
                .frame(width: side, height: side)
                .clipped()

                if overlayCount > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                    Text("+\(overlayCount)")
                        .font(.system(size: AppConstants.UI.FontSize.body, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
        }
        .buttonStyle(.plain)
    }
}

private struct GalleryStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Horizontal-swipe swiper through the album originals. Uses
/// `MediaViewer` for each item so zoom / retry behaviour matches the
/// stand-alone photo path.
///
/// We build the pager manually (HStack + offset + DragGesture) instead
/// of using `TabView(.verticalPage)` because `.verticalPage` competes
/// with the Digital Crown for input, and `ZoomablePhotoView` inside
/// `MediaViewer` already consumes the Crown for pinch-zoom. The result
/// of the conflict was that Crown rotation just zoomed the current photo
/// and never advanced to the next item. With a horizontal DragGesture
/// the Crown is left exclusively to MediaViewer (zoom), and side dots
/// communicate position.
struct AlbumGalleryView: View {
    let album: MessageAlbumInfo
    let startIndex: Int

    @State private var selection: Int
    @State private var dragOffset: CGFloat = 0

    /// Minimum horizontal translation to commit a page swap. Watch screens
    /// are narrow, so we use 25% of viewport width as the threshold
    /// (matches Photos.app behaviour on watchOS).
    private static let swipeThresholdFraction: CGFloat = 0.25

    init(album: MessageAlbumInfo, startIndex: Int) {
        self.album = album
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        let thumbs = album.thumbnails
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                AlbumGalleryPages(thumbnails: thumbs, selection: selection, pageSize: geo.size)
                    .offset(x: -CGFloat(selection) * geo.size.width + dragOffset)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: selection)
                    .gesture(
                        DragGesture(minimumDistance: 16)
                            .onChanged { value in
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                let threshold = geo.size.width * Self.swipeThresholdFraction
                                let dx = value.translation.width
                                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.85)) {
                                    if dx < -threshold, selection < thumbs.count - 1 {
                                        selection += 1
                                        HapticManager.tap()
                                    } else if dx > threshold, selection > 0 {
                                        selection -= 1
                                        HapticManager.tap()
                                    }
                                    dragOffset = 0
                                }
                            }
                    )

                if thumbs.count > 1 {
                    pageDots(count: thumbs.count)
                        .padding(.trailing, 4)
                }
            }
        }
    }

    private func pageDots(count: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == selection
                          ? WristTheme.Palette.primaryText
                          : WristTheme.Palette.primaryText.opacity(0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background(
            Capsule().fill(Color.black.opacity(0.25))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Photo"))
        .accessibilityValue("\(selection + 1) / \(count)")
    }
}

/// The pages of an album gallery side by side: a viewer for every photo,
/// all built at once. Only the page on screen downloads. Only it and its
/// neighbours keep a decoded photo, so paging through an album holds the
/// bitmaps of three pages at most and not of every page shown.
struct AlbumGalleryPages: View {
    let thumbnails: [AlbumThumbnail]
    let selection: Int
    let pageSize: CGSize

    /// Whether the page at `index` keeps its decoded photo while `selection`
    /// is on screen. A page that does not loads its photo again from the
    /// file TDLib holds when it is paged back to, as it did the first time.
    static func keepsPhoto(at index: Int, selection: Int) -> Bool {
        abs(index - selection) <= AppConstants.UI.Viewer.galleryKeptPageReach
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, thumb in
                MediaViewer(
                    fileId: thumb.fileId,
                    mode: .photo,
                    title: L10n.string("Photo"),
                    isActive: index == selection,
                    keepsImage: Self.keepsPhoto(at: index, selection: selection),
                    previewFileId: thumb.previewFileId
                )
                .frame(width: pageSize.width, height: pageSize.height)
            }
        }
    }
}

/// Compared by data only, like `MessageRow`.
extension AlbumView: Equatable {
    nonisolated static func == (lhs: AlbumView, rhs: AlbumView) -> Bool {
        lhs.album == rhs.album && lhs.isGroup == rhs.isGroup && lhs.availableWidth == rhs.availableWidth
    }
}
