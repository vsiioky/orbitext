import Foundation
import os

/// What the chat screen should present after an inline button press.
enum BotButtonResult: Equatable {
    /// Nothing to show: a silent callback answer, or an error that
    /// ErrorPresenter already surfaced.
    case done
    /// Short neutral notice (non-alert callback answers, unsupported buttons).
    case notice(String)
    /// Modal text (show_alert answers, copy_text buttons - the watch has no
    /// pasteboard, so the text is shown instead).
    case alert(String)
    case openLink(URL)
    case openChat(ChatInfo)
    case openContact(ContactInfo)
}

extension MessageManager {
    // MARK: - Inline keyboards

    func pressInlineButton(_ button: InlineKeyboardButton, in message: MessageInfo) async -> BotButtonResult {
        // A message still in TDLib's send queue has only a
        // local id, which callback queries reject.
        guard !message.isSending else { return .done }
        switch button.action {
        case .callback(let data):
            return await answerCallback(chatId: message.chatId, messageId: message.id, data: data)
        case .url(let link), .loginUrl(let link):
            // Login URLs fall back to plain links, which TDLib documents as
            // the required handling when authorization is not performed.
            return await openBotLink(link)
        case .user(let userId):
            return await botRequest { try await .openContact(service.getContact(userId: userId)) }
        case .copyText(let text):
            return text.isEmpty ? .done : .alert(text)
        case .callbackWithPassword, .callbackGame, .webApp, .switchInline, .buy, .unsupported:
            return .notice(L10n.string("Not available on Apple Watch"))
        }
    }

    func answerCallback(chatId: Int64, messageId: Int64, data: String) async -> BotButtonResult {
        do {
            let answer = try await service.getCallbackQueryAnswer(chatId: chatId, messageId: messageId, data: data)
            if !answer.url.isEmpty {
                return await openBotLink(answer.url)
            }
            guard !answer.text.isEmpty else { return .done }
            return answer.showAlert ? .alert(answer.text) : .notice(answer.text)
        } catch is CancellationError {
            return .done
        } catch BotInteractionError.botNotResponding {
            // Official clients just clear the button's progress state here;
            // a neutral notice explains why nothing happened.
            return .notice(L10n.string("The bot did not respond"))
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return .done
        }
    }

    /// Public Telegram links open the chat in-app; other links are handed
    /// to the link sheet, which asks before leaving the app.
    func openBotLink(_ link: String) async -> BotButtonResult {
        switch TelegramLink(string: link) {
        case .publicChat(let username):
            return await botRequest { try await .openChat(service.getChat(username: username)) }
        case .external(let url):
            return .openLink(url)
        case .unsupported:
            return .notice(L10n.string("Not available on Apple Watch"))
        case nil:
            return .notice(L10n.string("Invalid link"))
        }
    }

    // MARK: - Reply keyboards

    @discardableResult
    func sharePhoneNumber(chatId: Int64) async -> Bool {
        do {
            _ = try await service.sharePhoneNumber(chatId: chatId)
            HapticManager.messageSent()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return false
        }
    }

    private func botRequest(_ request: () async throws -> BotButtonResult) async -> BotButtonResult {
        do {
            return try await request()
        } catch is CancellationError {
            return .done
        } catch {
            errorPresenter?.show(error)
            HapticManager.error()
            return .done
        }
    }
}
