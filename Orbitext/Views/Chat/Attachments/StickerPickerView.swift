import SwiftUI

struct StickerPickerView: View {
    @Environment(MessageManager.self) private var messageManager
    @Environment(AppRouter.self) private var router
    let chatId: Int64

    @State private var stickers: [StickerOption] = []
    @State private var selectedSticker: StickerOption?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var sendFailed = false
    @State private var isSending = false
    @State private var isVisible = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        Group {
            if let selectedSticker {
                stickerPreview(selectedSticker)
            } else {
                stickerList
            }
        }
        .navigationTitle(L10n.string(selectedSticker == nil ? "Recent stickers" : "Sticker"))
        .background { WristScreenBackground() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task {
            if !hasLoaded { await loadStickers() }
        }
    }

    private var stickerList: some View {
        ScrollView {
            if isLoading {
                ProgressView(L10n.string("Loading"))
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if loadFailed {
                stateContent("Could not load stickers", symbol: "exclamationmark.bubble")
            } else if stickers.isEmpty {
                stateContent("No recent stickers", symbol: "face.smiling")
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(stickers) { sticker in
                        Button {
                            sendFailed = false
                            selectedSticker = sticker
                        } label: {
                            StickerOptionThumbnail(sticker: sticker)
                                .frame(height: 64)
                                .frame(maxWidth: .infinity)
                                .padding(4)
                                .background(WristGlassBackground(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(sticker.emoji) \(L10n.string("Preview sticker"))")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func stateContent(_ key: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L10n.string(key))
                .font(.callout)
                .multilineTextAlignment(.center)
            if !loadFailed {
                Text(L10n.string("Use a sticker in Telegram to find it here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L10n.string("Retry")) {
                Task { await loadStickers() }
            }
            .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
        }
        .padding(12)
        .background(WristGlassBackground())
    }

    private func stickerPreview(_ sticker: StickerOption) -> some View {
        List {
            StickerView(emoji: sticker.emoji, fileId: sticker.fileId, thumbnailFileId: sticker.thumbnailFileId)
                .frame(maxWidth: .infinity, minHeight: 90)
                .wristGlassRow()

            if sendFailed {
                Text(L10n.string("Sticker was not sent. Try again."))
                    .font(.caption)
                    .foregroundStyle(WristTheme.Palette.danger)
                    .wristGlassRow()
            }

            Button {
                Task { await send(sticker) }
            } label: {
                HStack {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(L10n.string(isSending ? "Sending sticker" : "Send sticker"))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(WristTheme.Palette.accent)
            .disabled(isSending)
            .wristGlassRow()

            Button(L10n.string("Choose another sticker")) {
                selectedSticker = nil
                sendFailed = false
            }
            .frame(minHeight: 44)
            .disabled(isSending)
            .wristGlassRow()
        }
        .wristListStyle()
    }

    @MainActor
    private func loadStickers() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let loaded = try await messageManager.loadRecentStickers()
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            stickers = Array(loaded.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(30))
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    @MainActor
    private func send(_ sticker: StickerOption) async {
        guard !isSending else { return }
        isSending = true
        sendFailed = false
        defer { isSending = false }
        let sent = await messageManager.sendSticker(chatId: chatId, sticker: sticker)
        guard isVisible else { return }
        if sent {
            router.openChat(chatId)
        } else {
            sendFailed = true
        }
    }
}

private struct StickerOptionThumbnail: View {
    let sticker: StickerOption

    var body: some View {
        if let thumbnail = sticker.thumbnailFileId, !thumbnail.isEmpty {
            TDLibImage(fileId: thumbnail, contentMode: .fit, maxDimension: 64) {
                Text(sticker.emoji.isEmpty ? "◻︎" : sticker.emoji)
                    .font(.largeTitle)
            }
        } else {
            Text(sticker.emoji.isEmpty ? "◻︎" : sticker.emoji)
                .font(.largeTitle)
        }
    }
}
