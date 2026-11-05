import SwiftUI

// Telegram-style bubble with a small tail on the sender side.
//
// IMPORTANT: SwiftUI clips Shape used via .background(_, in:) to the
// view's bounds, so the tail MUST live inside the view rect. Callers
// extend the rect by `tailExtent` on the tail side via padding so
// the tail has room to draw without overlapping the message content.
struct MessageBubbleShape: Shape {
    let isOutgoing: Bool
    var cornerRadius: CGFloat = AppConstants.UI.Bubble.cornerRadius

    static let tailExtent: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let tail = MessageBubbleShape.tailExtent
        let bodyMinX = isOutgoing ? rect.minX : rect.minX + tail
        let bodyMaxX = isOutgoing ? rect.maxX - tail : rect.maxX

        var path = Path()

        path.move(to: CGPoint(x: bodyMinX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMaxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: bodyMaxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        if isOutgoing {
            path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - r))
            // Tail: curve out to bottom-right of full rect, then sweep back
            // toward the body. The two control points create the rounded
            // "drip" silhouette.
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: bodyMaxX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: bodyMaxX - r, y: rect.maxY),
                control: CGPoint(x: bodyMaxX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - r))
            path.addArc(
                center: CGPoint(x: bodyMaxX - r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }

        if isOutgoing {
            path.addLine(to: CGPoint(x: bodyMinX + r, y: rect.maxY))
            path.addArc(
                center: CGPoint(x: bodyMinX + r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: bodyMinX + r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: bodyMinX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: bodyMinX, y: rect.maxY - r),
                control: CGPoint(x: bodyMinX, y: rect.maxY)
            )
        }

        path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: bodyMinX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
