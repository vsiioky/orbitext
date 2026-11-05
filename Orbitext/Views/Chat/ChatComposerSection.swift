import SwiftUI

/// The floating composer and the bot state it shows. It reads the chat from
/// the directory and the bot store, so the screen around it does not.
struct ChatComposerSection: View {
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(BotKeyboardStore.self) private var botKeyboardStore
    let chatId: Int64
    var fallback: ChatInfo?
    /// Whether the viewport rests where the composer belongs. The bar stays
    /// mounted while hidden, which keeps its draft and an in-flight send.
    let isVisible: Bool
    let onAttach: () -> Void
    let onBotMenu: () -> Void

    var body: some View {
        if !chatRepository.chat(id: chatId, fallback: fallback).isChannel {
            let replyKeyboard = botKeyboardStore.replyKeyboard(for: chatId)
            ChatComposerBar(
                chatId: chatId,
                botMenuIcon: botMenuIcon,
                isBotKeyboardActive: replyKeyboard?.keyboard != nil && replyKeyboard?.isAwaitingInput == true,
                placeholder: replyKeyboard?.placeholder,
                replyToMessageId: replyKeyboard?.forceReplyPlaceholder != nil ? replyKeyboard?.messageId : nil,
                onAttach: onAttach,
                onBotMenu: onBotMenu,
                onSent: consumeForceReply
            )
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : ChatBottomInset.composerHeight)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
        }
    }

    /// Keyboard glyph while the bot has a reply keyboard, the menu glyph
    /// Telegram uses for a command list, nothing for chats without bots.
    private var botMenuIcon: String? {
        if botKeyboardStore.replyKeyboard(for: chatId)?.keyboard != nil { return "keyboard" }
        return botKeyboardStore.commands(for: chatId).isEmpty ? nil : "line.3.horizontal"
    }

    /// A force-reply request is answered by the next message sent from the
    /// composer; TDLib then expects deleteChatReplyMarkup.
    private func consumeForceReply() {
        guard let active = botKeyboardStore.replyKeyboard(for: chatId),
              active.forceReplyPlaceholder != nil else { return }
        Task { await botKeyboardStore.consumeReplyKeyboard(chatId: chatId, messageId: active.messageId) }
    }
}
