import SwiftUI

struct ChatAttachmentsView: View {
    let chatId: Int64

    var body: some View {
        List {
            NavigationLink(value: AppDestination.stickerPicker(chatId: chatId)) {
                attachmentLabel("Sticker", symbol: "face.smiling", color: .yellow)
            }
            .wristGlassRow()

            NavigationLink(value: AppDestination.voiceRecorder(chatId: chatId)) {
                attachmentLabel("Voice Message", symbol: "mic.fill", color: WristTheme.Palette.voice)
            }
            .wristGlassRow()

            NavigationLink(value: AppDestination.locationShare(chatId: chatId)) {
                attachmentLabel("Location", symbol: "location.fill", color: WristTheme.Palette.accent)
            }
            .wristGlassRow()
        }
        .wristListStyle()
        .navigationTitle(L10n.string("Attach"))
    }

    private func attachmentLabel(_ key: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(WristGlassBackground(cornerRadius: 18, tint: color))
            Text(L10n.string(key))
                .font(.body)
                .lineLimit(2)
        }
        .frame(minHeight: 44)
    }
}
