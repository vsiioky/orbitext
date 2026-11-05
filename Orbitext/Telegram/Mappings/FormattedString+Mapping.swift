import Foundation

// MARK: - FormattedString / TextEntity from typed TDApi

//
// Bridges the generated TDApi types into the domain model. Message text
// and captions only take this typed path. customEmoji is kept like in
// the dict path although the watch has no custom-emoji renderer (the
// text glyph is the fallback).

extension FormattedString {
    /// Build a FormattedString from a decoded TDApi.FormattedText. Empty
    /// payloads round-trip to `.empty` so call sites can keep the
    /// `caption.isEmpty` idiom.
    init(tdApi text: TDApi.FormattedText) {
        self.text = text.text
        self.entities = text.entities.compactMap { TextEntity(tdApi: $0) }
    }
}

extension TextEntity {
    init?(tdApi entity: TDApi.TextEntity) {
        let offset = Int(entity.offset)
        let length = Int(entity.length)
        guard length > 0, let type = entity.type else { return nil }
        switch type {
        case .textEntityTypeBold:
            self = .bold(offset: offset, length: length)
        case .textEntityTypeItalic:
            self = .italic(offset: offset, length: length)
        case .textEntityTypeCode:
            self = .code(offset: offset, length: length)
        case .textEntityTypePre:
            self = .pre(offset: offset, length: length)
        case .textEntityTypePreCode(let pc):
            self = .preCode(offset: offset, length: length, language: pc.language)
        case .textEntityTypeUnderline:
            self = .underline(offset: offset, length: length)
        case .textEntityTypeStrikethrough:
            self = .strikethrough(offset: offset, length: length)
        case .textEntityTypeMention:
            self = .mention(offset: offset, length: length)
        case .textEntityTypeMentionName(let m):
            self = .mentionName(offset: offset, length: length, userId: m.userId)
        case .textEntityTypeUrl:
            self = .url(offset: offset, length: length)
        case .textEntityTypeTextUrl(let u):
            self = .textUrl(offset: offset, length: length, href: u.url)
        case .textEntityTypeEmailAddress:
            self = .email(offset: offset, length: length)
        case .textEntityTypePhoneNumber:
            self = .phone(offset: offset, length: length)
        case .textEntityTypeHashtag:
            self = .hashtag(offset: offset, length: length)
        case .textEntityTypeCashtag:
            self = .cashtag(offset: offset, length: length)
        case .textEntityTypeBotCommand:
            self = .botCommand(offset: offset, length: length)
        case .textEntityTypeSpoiler:
            self = .spoiler(offset: offset, length: length)
        case .textEntityTypeBlockQuote,
             .textEntityTypeExpandableBlockQuote:
            self = .blockQuote(offset: offset, length: length)
        case .textEntityTypeCustomEmoji(let e):
            self = .customEmoji(offset: offset, length: length, emojiId: e.customEmojiId)
        case .textEntityTypeBankCardNumber,
             .textEntityTypeMediaTimestamp,
             .textEntityTypeDateTime,
             .unknown:
            // Not representable in the domain TextEntity. The dict
            // path skips these too (they're not in the switch in
            // TDLibService+FormattedTextParser.swift), so dropping
            // here preserves parity. Entity types newer than the
            // schema land in .unknown.
            return nil
        }
    }
}
