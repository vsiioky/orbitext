import SwiftUI

struct ZoomablePhotoView: View {
    let image: UIImage
    @Binding var scale: CGFloat
    /// Whether this view should claim Digital Crown focus. In an album
    /// gallery only the currently visible page should be focusable, or
    /// the off-screen pages steal the crown and zoom does nothing
    /// until the user taps to transfer focus.
    var isActive = true
    @State private var settledOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let fittedSize = fittedImageSize(in: viewportSize)
            let displayedOffset = clampedOffset(
                CGSize(
                    width: settledOffset.width + dragOffset.width,
                    height: settledOffset.height + dragOffset.height
                ),
                scale: scale,
                viewportSize: viewportSize,
                fittedImageSize: fittedSize
            )

            // Pan gesture is installed ONLY while the photo is zoomed in.
            // At scale ~= 1.0 we deliberately leave the image without a
            // DragGesture so a parent pager (AlbumGalleryView) can
            // recognize horizontal swipes between photos. With the gesture
            // unconditionally installed SwiftUI claims the drag even when
            // our onChanged early-returns, and the parent never sees it.
            let base = Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(displayedOffset)
                .frame(width: viewportSize.width, height: viewportSize.height)
                .contentShape(Rectangle())
                .focusable(isActive)
                .digitalCrownRotation(
                    $scale,
                    from: 1.0,
                    through: 10.0,
                    by: 0.1,
                    sensitivity: .medium
                )

            Group {
                if scale > 1.01 {
                    base.gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                settledOffset = clampedOffset(
                                    CGSize(
                                        width: settledOffset.width + value.translation.width,
                                        height: settledOffset.height + value.translation.height
                                    ),
                                    scale: scale,
                                    viewportSize: viewportSize,
                                    fittedImageSize: fittedSize
                                )
                                dragOffset = .zero
                            }
                    )
                } else {
                    base
                }
            }
                .onChange(of: scale) { _, newScale in
                    if newScale <= 1.01 {
                        settledOffset = .zero
                        dragOffset = .zero
                    } else {
                        settledOffset = clampedOffset(
                            settledOffset,
                            scale: newScale,
                            viewportSize: viewportSize,
                            fittedImageSize: fittedSize
                        )
                        dragOffset = .zero
                    }
                }
        }
    }

    // MARK: - Layout Helpers

    private func fittedImageSize(in viewportSize: CGSize) -> CGSize {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              image.size.width > 0,
              image.size.height > 0 else {
            return viewportSize
        }

        let imageAspect = image.size.width / image.size.height
        let viewportAspect = viewportSize.width / viewportSize.height

        if imageAspect > viewportAspect {
            let width = viewportSize.width
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = viewportSize.height
            return CGSize(width: height * imageAspect, height: height)
        }
    }

    private func clampedOffset(
        _ proposedOffset: CGSize,
        scale: CGFloat,
        viewportSize: CGSize,
        fittedImageSize: CGSize
    ) -> CGSize {
        guard scale > 1.01 else { return .zero }

        let scaledWidth = fittedImageSize.width * scale
        let scaledHeight = fittedImageSize.height * scale
        let maxX = max(0, (scaledWidth - viewportSize.width) / 2)
        let maxY = max(0, (scaledHeight - viewportSize.height) / 2)

        return CGSize(
            width: min(max(proposedOffset.width, -maxX), maxX),
            height: min(max(proposedOffset.height, -maxY), maxY)
        )
    }
}
