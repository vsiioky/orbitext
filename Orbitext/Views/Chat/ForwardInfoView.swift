import SwiftUI

struct ForwardInfoView: View {
    let origin: MessageOrigin

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: origin.isChannel ? "megaphone.fill" : "arrowshape.turn.up.right.fill")
                .font(.system(size: AppConstants.UI.FontSize.micro))
            Text(L10n.format("Forwarded from %@", origin.displayName))
                .font(.system(size: AppConstants.UI.FontSize.tiny, weight: .medium))
        }
        .foregroundStyle(WristTheme.Palette.success.opacity(0.9))
        .lineLimit(1)
    }
}
