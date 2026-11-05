import SwiftUI

struct ReplyPreviewView: View {
    let senderName: String?
    let preview: FormattedString?
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isOutgoing ? .white : WristTheme.Palette.accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                if let name = senderName {
                    Text(name)
                        .font(.system(size: AppConstants.UI.FontSize.body, weight: .semibold))
                        .foregroundStyle(isOutgoing ? .white : WristTheme.Palette.accent)
                        .lineLimit(1)
                }
                if let preview, !preview.isEmpty {
                    // A reply preview has no tap-to-reveal, so quoted spoilers stay masked.
                    let masked = preview.maskingSpoilers
                    Text(masked.attributedString)
                        .font(.system(size: AppConstants.UI.FontSize.body))
                        .foregroundStyle(isOutgoing ? .white.opacity(0.8) : .secondary)
                        .lineLimit(2)
                        .accessibilityLabel(masked.text.speakingSpoilerMasks)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
