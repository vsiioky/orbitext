import SwiftUI

/// Centered capsule for system messages (pinned message, chat created,
/// member joined/left). These used to render as full
/// bubbles wasting ~50pt of vertical real estate; a 25pt pill recovers
/// that scroll space on the watch.
struct ServicePillView: View {
    let text: String
    var onTap: (() -> Void)?

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(WristTheme.Palette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(WristTheme.Palette.raisedSurface.opacity(0.7))
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Capsule())
            .onTapGesture {
                if let onTap {
                    HapticManager.tap()
                    onTap()
                }
            }
            .accessibilityLabel(text)
            .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}
