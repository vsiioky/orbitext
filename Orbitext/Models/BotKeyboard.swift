import Foundation

// MARK: - Bot keyboards and commands

/// Visual emphasis a bot requested for a keyboard button (TDLib ButtonStyle).
enum BotButtonStyle: String, Equatable, Codable, Sendable {
    case standard
    case primary
    case danger
    case success
}

/// One button of an inline keyboard attached under a bot message.
struct InlineKeyboardButton: Equatable, Codable, Sendable {
    enum Action: Equatable, Codable, Sendable {
        /// Callback data stays in TDLib's base64 `bytes` form so it can be
        /// sent back verbatim in callbackQueryPayloadData.
        case callback(data: String)
        case callbackWithPassword
        case callbackGame
        case url(String)
        case loginUrl(String)
        case webApp(String)
        case switchInline(query: String)
        case buy
        case user(userId: Int64)
        case copyText(String)
        case unsupported(String)
    }

    let text: String
    var style: BotButtonStyle = .standard
    let action: Action

    /// Buttons that open something outside the chat get a link glyph,
    /// matching the arrow Telegram clients draw in the button corner.
    var opensLink: Bool {
        switch action {
        case .url, .loginUrl, .webApp: return true
        default: return false
        }
    }
}

/// One button of a reply keyboard (the bot-supplied keyboard that replaces
/// the system keyboard in Telegram clients).
struct ReplyKeyboardButton: Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case text
        case requestLocation
        case requestPhoneNumber
        case unsupported(String)
    }

    let text: String
    var style: BotButtonStyle = .standard
    let kind: Kind

    var isSupported: Bool {
        if case .unsupported = kind { return false }
        return true
    }
}

struct ReplyKeyboard: Equatable, Codable, Sendable {
    let rows: [[ReplyKeyboardButton]]
    var isOneTime = false
    var isPersistent = false
    /// TDLib: "the keyboard must automatically be shown to the current
    /// user". deleteChatReplyMarkup clears it on a used one-time keyboard
    /// but keeps the keyboard itself, which stays reachable from the menu.
    var isPersonal = true
    var placeholder = ""

    /// A one-time keyboard that has already been used.
    var isCollapsed: Bool { isOneTime && !isPersonal }
}

/// Domain form of TDLib's ReplyMarkup.
enum ReplyMarkup: Equatable, Codable, Sendable {
    case inlineKeyboard([[InlineKeyboardButton]])
    case showKeyboard(ReplyKeyboard)
    case removeKeyboard
    case forceReply(placeholder: String)

    var inlineKeyboardRows: [[InlineKeyboardButton]]? {
        guard case .inlineKeyboard(let rows) = self, !rows.isEmpty else { return nil }
        return rows
    }
}

/// The reply keyboard (or force-reply request) a bot currently has active
/// in a chat, together with the message that carries it. TDLib reports it
/// via chat.reply_markup_message_id / updateChatReplyMarkup.
struct ChatReplyKeyboard: Equatable, Sendable {
    let messageId: Int64
    let markup: ReplyMarkup

    var keyboard: ReplyKeyboard? {
        if case .showKeyboard(let keyboard) = markup, !keyboard.rows.isEmpty { return keyboard }
        return nil
    }

    var forceReplyPlaceholder: String? {
        if case .forceReply(let placeholder) = markup { return placeholder }
        return nil
    }

    /// The keyboard is up and waiting for input (drives the composer's
    /// highlighted menu button and placeholder).
    var isAwaitingInput: Bool {
        if let keyboard { return !keyboard.isCollapsed }
        return forceReplyPlaceholder != nil
    }

    var placeholder: String? {
        guard isAwaitingInput else { return nil }
        let text = keyboard?.placeholder ?? forceReplyPlaceholder ?? ""
        return text.isEmpty ? nil : text
    }

    /// State after the keyboard was used: a one-time keyboard collapses
    /// (TDLib keeps it, see ReplyKeyboard.isPersonal); force reply is gone.
    func consumed() -> ChatReplyKeyboard? {
        guard var keyboard, keyboard.isOneTime else { return nil }
        keyboard.isPersonal = false
        return ChatReplyKeyboard(messageId: messageId, markup: .showKeyboard(keyboard))
    }

    /// Only keyboards and force-reply requests stay active at chat level.
    init?(messageId: Int64, markup: ReplyMarkup?) {
        guard messageId != 0, let markup else { return nil }
        switch markup {
        case .showKeyboard(let keyboard) where !keyboard.rows.isEmpty:
            break
        case .forceReply:
            break
        default:
            return nil
        }
        self.messageId = messageId
        self.markup = markup
    }
}

/// A command from a bot's command menu (TDLib botCommand).
struct BotCommandInfo: Identifiable, Equatable, Hashable, Sendable {
    /// Command name without the leading slash, as TDLib reports it.
    let command: String
    let description: String
    /// Set in groups so the command reaches the right bot.
    var botUsername: String?

    var id: String { messageText }

    var messageText: String {
        guard let botUsername, !botUsername.isEmpty else { return "/\(command)" }
        return "/\(command)@\(botUsername)"
    }
}

/// TDLib callbackQueryAnswer.
struct BotCallbackAnswer: Equatable, Sendable {
    var text = ""
    var showAlert = false
    var url = ""
}

enum BotInteractionError: LocalizedError, Equatable {
    case unsupported
    case botNotResponding

    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.string("Not available on Apple Watch")
        case .botNotResponding: L10n.string("The bot did not respond")
        }
    }
}
