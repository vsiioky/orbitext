import Foundation
import Observation
import os

/// Chat-level bot state behind the composer's bot menu button: the active
/// reply keyboard (or force-reply request) and the bots' command menus.
/// Inline keyboards live on MessageInfo instead, since each belongs to
/// its own message.
@MainActor
@Observable
final class BotKeyboardStore {
    private let service: TelegramServiceProtocol

    private var replyKeyboards: [Int64: ChatReplyKeyboard] = [:]
    private var commandsByChatId: [Int64: [BotCommandInfo]] = [:]
    /// Bumped by every live change so a slower load that started earlier
    /// cannot overwrite newer state for the same chat.
    private var revisions: [Int64: Int] = [:]
    /// Bumped by resetAll so loads started under the previous session
    /// cannot repopulate the store after logout.
    private var epoch = 0

    init(service: TelegramServiceProtocol) {
        self.service = service
    }

    func replyKeyboard(for chatId: Int64) -> ChatReplyKeyboard? {
        replyKeyboards[chatId]
    }

    func commands(for chatId: Int64) -> [BotCommandInfo] {
        commandsByChatId[chatId] ?? []
    }

    func hasMenu(for chatId: Int64) -> Bool {
        replyKeyboards[chatId]?.keyboard != nil || !commands(for: chatId).isEmpty
    }

    /// Loads the active reply keyboard and the command menu for a chat that
    /// just opened. Failures keep the previous state: the menu is an
    /// optional affordance, not something to report as an error.
    func load(chatId: Int64) async {
        let startEpoch = epoch
        let revision = revisions[chatId, default: 0]
        // The keyboard is a local database read; the command menu may need
        // the network, so the keyboard is applied without waiting for it.
        async let commands = loadCommands(chatId: chatId)
        let message = await loadReplyMarkupMessage(chatId: chatId)
        if !Task.isCancelled, epoch == startEpoch, let message, revisions[chatId, default: 0] == revision {
            replyKeyboards[chatId] = message.flatMap { ChatReplyKeyboard(messageId: $0.id, markup: $0.replyMarkup) }
        }
        let loadedCommands = await commands
        guard !Task.isCancelled, epoch == startEpoch, let loadedCommands else { return }
        commandsByChatId[chatId] = loadedCommands
    }

    /// updateChatReplyMarkup.
    func handleReplyMarkupChanged(chatId: Int64, message: MessageInfo?) {
        revisions[chatId, default: 0] += 1
        replyKeyboards[chatId] = message.flatMap { ChatReplyKeyboard(messageId: $0.id, markup: $0.replyMarkup) }
    }

    /// Collapses a used one-time keyboard or drops an answered force-reply
    /// request. TDLib requires deleteChatReplyMarkup after either; for a
    /// one-time keyboard it answers with the same keyboard marked
    /// non-personal, which the local state already mirrors.
    func consumeReplyKeyboard(chatId: Int64, messageId: Int64) async {
        guard let active = replyKeyboards[chatId], active.messageId == messageId else { return }
        revisions[chatId, default: 0] += 1
        replyKeyboards[chatId] = active.consumed()
        do {
            try await service.deleteChatReplyMarkup(chatId: chatId, messageId: messageId)
        } catch {
            Logger.app.warning("deleteChatReplyMarkup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user left the chat: the command menu and the revision counter go,
    /// one entry each for every chat ever opened, bots and not. The next open
    /// loads them again. The reply keyboard stays: TDLib announces it for
    /// any chat, and only chat screens read it.
    func release(chatId: Int64) {
        commandsByChatId[chatId] = nil
        revisions[chatId] = nil
    }

    /// Called after the account session has closed.
    func resetAll() {
        epoch += 1
        replyKeyboards.removeAll()
        commandsByChatId.removeAll()
        revisions.removeAll()
    }

    /// Outer nil: the request failed; inner nil: the chat has no keyboard.
    private func loadReplyMarkupMessage(chatId: Int64) async -> MessageInfo?? {
        do {
            return try await .some(service.getReplyMarkupMessage(chatId: chatId))
        } catch {
            Logger.app.debug("reply keyboard load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadCommands(chatId: Int64) async -> [BotCommandInfo]? {
        do {
            return try await service.getBotCommands(chatId: chatId)
        } catch {
            Logger.app.debug("bot commands load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
