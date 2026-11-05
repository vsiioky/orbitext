import SwiftUI

// Small views for what the chat screen takes from the chat directory. The
// directory changes whenever any chat does, so each is its own scope: a change
// redraws the few views below, not the screen that holds them.

/// "Someone is typing" row at the end of the history.
struct ChatTypingFooter: View {
    @Environment(ChatRepository.self) private var chatRepository
    let chatId: Int64
    var fallback: ChatInfo?

    var body: some View {
        let chat = chatRepository.chat(id: chatId, fallback: fallback)
        if chat.isTyping {
            TypingIndicatorView(names: chat.typingUserNames)
                .padding(AppConstants.UI.compactRowInsets)
        }
    }
}

/// Room for the floating composer at the end of the history. It stays when
/// the composer hides, so the scroll geometry does not move; a channel has no
/// composer and needs none.
struct ChatBottomInset: View {
    @Environment(ChatRepository.self) private var chatRepository
    let chatId: Int64
    var fallback: ChatInfo?

    var body: some View {
        Color.clear
            .frame(height: chatRepository.chat(id: chatId, fallback: fallback).isChannel ? 0 : Self.composerHeight)
            .allowsHitTesting(false)
    }

    static let composerHeight: CGFloat = 54
}

/// Copies whether the chat is a group into the screen's state, so that the
/// screen draws sender names without reading the directory itself.
struct ChatGroupFlagReader: View {
    @Environment(ChatRepository.self) private var chatRepository
    let chatId: Int64
    var fallback: ChatInfo?
    @Binding var isGroup: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: chatRepository.chat(id: chatId, fallback: fallback).isGroup, initial: true) { _, newValue in
                isGroup = newValue
            }
    }
}
