import SwiftUI

/// Confirmation for an external link from a bot button. Links leave the
/// app, so the user sees the address first; the QR code lets them open
/// pages that are impractical on the watch with their phone instead.
struct BotLinkView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Bot-controlled: never truncate the host, or a long
                // subdomain could hide the real registrable domain.
                Text(url.host ?? url.absoluteString)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)

                Button(L10n.string("Open")) {
                    openURL(url)
                    dismiss()
                }
                .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accentSoft))
                .accessibilityIdentifier("bot-link-open")

                QRCodeView(text: url.absoluteString)
                    .frame(width: AppConstants.UI.BotKeyboard.linkQRSize, height: AppConstants.UI.BotKeyboard.linkQRSize)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text(L10n.string("Scan with your phone"))
                    .font(.caption2)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.string("Open link"))
    }
}
