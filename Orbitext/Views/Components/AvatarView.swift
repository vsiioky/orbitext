import SwiftUI

/// Reusable avatar circle used across chat list, contacts, and profile screens.
struct AvatarView: View {
    @Environment(\.displayScale) private var displayScale
    let title: String
    let id: Int64
    var photoFileId: String?
    var isGroup = false
    var isOnline = false
    var size: CGFloat = 32
    var isPinned = false

    var body: some View {
        ZStack {
            if let photoFileId, let fileId = Int32(photoFileId), fileId > 0 {
                TDLibImage(fileId: photoFileId, maxDimension: size * displayScale, showsStatusOverlays: false) {
                    initialsPlaceholder
                }
                // Reset the displayed bitmap immediately when Telegram replaces
                // the photo, including while the previous download finishes.
                .id(photoFileId)
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                initialsPlaceholder
            }

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: AppConstants.UI.FontSize.micro))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.38, y: -(size * 0.38))
            }

            if isOnline {
                Circle()
                    .fill(WristTheme.Palette.success)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(WristTheme.Palette.canvas, lineWidth: 1.5))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .accessibilityLabel(isOnline ? L10n.format("%@, online", title) : title)
        .accessibilityHidden(true)
    }

    private var initialsPlaceholder: some View {
        ZStack {
            Circle()
                .fill(avatarColor)

            if initials.isEmpty {
                Image(systemName: isGroup ? "person.2.fill" : "person.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }

    private var avatarColor: Color {
        WristTheme.Palette.avatarColor(for: id)
    }
}
