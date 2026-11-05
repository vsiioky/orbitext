import Foundation

// MARK: - ReplyMarkup from typed TDApi

//
// Bot keyboards, from the generated ReplyMarkup (scripts/codegen-roots.txt
// lists which button types are generated; the rest decode to .unknown(tag:)
// and map to the unsupported cases). Service-free so tests can call it
// directly.

extension ReplyMarkup {
    /// Returns nil for an unknown markup kind and for an inline keyboard
    /// without buttons, so callers can treat nil as "no markup".
    init?(tdApi markup: TDApi.ReplyMarkup) {
        switch markup {
        case .replyMarkupInlineKeyboard(let inline):
            let rows = Self.rows(inline.rows, InlineKeyboardButton.init(tdApi:))
            guard !rows.isEmpty else { return nil }
            self = .inlineKeyboard(rows)
        case .replyMarkupShowKeyboard(let show):
            self = .showKeyboard(ReplyKeyboard(
                rows: Self.rows(show.rows, ReplyKeyboardButton.init(tdApi:)),
                isOneTime: show.oneTime,
                isPersistent: show.isPersistent,
                isPersonal: show.isPersonal,
                placeholder: show.inputFieldPlaceholder
            ))
        case .replyMarkupRemoveKeyboard:
            self = .removeKeyboard
        case .replyMarkupForceReply(let force):
            self = .forceReply(placeholder: force.inputFieldPlaceholder)
        case .unknown:
            return nil
        }
    }

    /// Drops buttons that fail to map and rows left empty by that.
    private static func rows<Source, Button>(_ rows: [[Source]], _ map: (Source) -> Button?) -> [[Button]] {
        rows.map { $0.compactMap(map) }.filter { !$0.isEmpty }
    }

    /// The raw-dict mappings of userFullInfo and the group full infos
    /// (BotCommand+Mapping.swift, TDLibService+Bots.swift) share these two:
    /// TDLib containers can arrive bridged as NSDictionary / NSArray at the
    /// JSON boundary, so accept both.
    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let nsDict = value as? NSDictionary else { return nil }
        var result = [String: Any](minimumCapacity: nsDict.count)
        for (key, value) in nsDict {
            if let key = key as? String { result[key] = value }
        }
        return result
    }

    static func array(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let nsArray = value as? NSArray { return nsArray.map(\.self) }
        return []
    }
}

extension BotButtonStyle {
    init(tdApi style: TDApi.ButtonStyle?) {
        switch style {
        case .buttonStylePrimary?: self = .primary
        case .buttonStyleDanger?: self = .danger
        case .buttonStyleSuccess?: self = .success
        case .buttonStyleDefault?, .unknown?, nil: self = .standard
        }
    }
}

extension InlineKeyboardButton {
    /// Nil for a button TDLib sent without text or type, and for a callback
    /// button without data: neither can be shown or pressed.
    init?(tdApi button: TDApi.InlineKeyboardButton) {
        guard !button.text.isEmpty, let type = button.type else { return nil }
        let action: Action
        switch type {
        case .inlineKeyboardButtonTypeCallback(let callback):
            guard !callback.data.isEmpty else { return nil }
            action = .callback(data: callback.data.base64EncodedString())
        case .inlineKeyboardButtonTypeCallbackWithPassword:
            action = .callbackWithPassword
        case .inlineKeyboardButtonTypeCallbackGame:
            action = .callbackGame
        case .inlineKeyboardButtonTypeUrl(let link):
            action = .url(link.url)
        case .inlineKeyboardButtonTypeLoginUrl(let link):
            action = .loginUrl(link.url)
        case .inlineKeyboardButtonTypeWebApp(let app):
            action = .webApp(app.url)
        case .inlineKeyboardButtonTypeSwitchInline(let inline):
            action = .switchInline(query: inline.query)
        case .inlineKeyboardButtonTypeBuy:
            action = .buy
        case .inlineKeyboardButtonTypeUser(let user):
            action = .user(userId: user.userId)
        case .inlineKeyboardButtonTypeCopyText(let copy):
            action = .copyText(copy.text)
        case .unknown(let tag):
            action = .unsupported(tag)
        }
        self.init(text: button.text, style: BotButtonStyle(tdApi: button.style), action: action)
    }
}

extension ReplyKeyboardButton {
    /// Nil for a button TDLib sent without text.
    init?(tdApi button: TDApi.KeyboardButton) {
        guard !button.text.isEmpty else { return nil }
        let kind: Kind
        switch button.type {
        // A missing type is a plain text button in older Bot API payloads.
        case .keyboardButtonTypeText?, nil:
            kind = .text
        case .keyboardButtonTypeRequestLocation?:
            kind = .requestLocation
        case .keyboardButtonTypeRequestPhoneNumber?:
            kind = .requestPhoneNumber
        case .unknown(let tag)?:
            kind = .unsupported(tag)
        }
        self.init(text: button.text, style: BotButtonStyle(tdApi: button.style), kind: kind)
    }
}
