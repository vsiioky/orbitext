import Foundation
import SwiftUI

// MARK: - TextEntity

/// One styled span in a FormattedString. Offsets and lengths are in
/// UTF-16 code units (TDLib's native unit), matching textEntity.offset
/// / textEntity.length in tdapi. Convert to String.Index via
/// String.utf16 before slicing.
enum TextEntity: Equatable, Hashable, Codable, Sendable {
    case bold(offset: Int, length: Int)
    case italic(offset: Int, length: Int)
    case code(offset: Int, length: Int)
    case pre(offset: Int, length: Int)
    case preCode(offset: Int, length: Int, language: String)
    case underline(offset: Int, length: Int)
    case strikethrough(offset: Int, length: Int)
    case mention(offset: Int, length: Int)
    case mentionName(offset: Int, length: Int, userId: Int64)
    case url(offset: Int, length: Int)
    case textUrl(offset: Int, length: Int, href: String)
    case email(offset: Int, length: Int)
    case phone(offset: Int, length: Int)
    case hashtag(offset: Int, length: Int)
    case cashtag(offset: Int, length: Int)
    case spoiler(offset: Int, length: Int)
    case blockQuote(offset: Int, length: Int)
    case botCommand(offset: Int, length: Int)
    case customEmoji(offset: Int, length: Int, emojiId: Int64)

    var offset: Int {
        switch self {
        case .bold(let o, _), .italic(let o, _), .code(let o, _), .pre(let o, _),
             .underline(let o, _), .strikethrough(let o, _), .mention(let o, _),
             .url(let o, _), .email(let o, _), .phone(let o, _), .hashtag(let o, _),
             .cashtag(let o, _), .spoiler(let o, _), .blockQuote(let o, _),
             .botCommand(let o, _):
            return o
        case .preCode(let o, _, _), .mentionName(let o, _, _),
             .textUrl(let o, _, _), .customEmoji(let o, _, _):
            return o
        }
    }

    var length: Int {
        switch self {
        case .bold(_, let l), .italic(_, let l), .code(_, let l), .pre(_, let l),
             .underline(_, let l), .strikethrough(_, let l), .mention(_, let l),
             .url(_, let l), .email(_, let l), .phone(_, let l), .hashtag(_, let l),
             .cashtag(_, let l), .spoiler(_, let l), .blockQuote(_, let l),
             .botCommand(_, let l):
            return l
        case .preCode(_, let l, _), .mentionName(_, let l, _),
             .textUrl(_, let l, _), .customEmoji(_, let l, _):
            return l
        }
    }
}

// MARK: - FormattedString

/// Plain text + Telegram entity list (bold/italic/spoiler/link/...).
/// Built once during parsing and cached. Renders through
/// `attributedString` for SwiftUI Text.
struct FormattedString: Equatable, Hashable, Codable, Sendable {
    var text: String
    var entities: [TextEntity]

    init(text: String, entities: [TextEntity] = []) {
        self.text = text
        self.entities = entities
    }

    static let empty = FormattedString(text: "", entities: [])

    var isEmpty: Bool { text.isEmpty }

    var hasSpoiler: Bool { entities.contains { if case .spoiler = $0 { return true } else { return false } } }
}

extension FormattedString: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.init(text: value, entities: [])
    }
}

// MARK: - Spoilers outside the chat bubble

extension FormattedString {
    /// Stands in for each UTF-16 unit of a hidden spoiler. A single BMP
    /// scalar per unit keeps the offsets of the remaining entities valid.
    static let spoilerMask: Character = "▒"

    /// For surfaces without tap-to-reveal: chat list, notifications,
    /// widget, search and reply previews.
    var maskingSpoilers: FormattedString {
        guard hasSpoiler else { return self }
        let spoilers = entities.compactMap { entity -> Range<Int>? in
            guard case .spoiler(let offset, let length) = entity, length > 0 else { return nil }
            return offset..<(offset + length)
        }
        let mask = Self.spoilerMask.utf16.first ?? 0
        let units = text.utf16.enumerated().map { index, unit in
            spoilers.contains { $0.contains(index) } ? mask : unit
        }
        // Drop the spoilers and anything styled inside them: a masked link
        // or mention must not stay tappable and open what it hides.
        let visible = entities.filter { entity in
            let range = entity.offset..<(entity.offset + entity.length)
            return !spoilers.contains { $0.overlaps(range) }
        }
        return FormattedString(text: String(decoding: units, as: UTF16.self), entities: visible)
    }
}

extension String {
    /// VoiceOver form of a masked preview: each run of spoiler mask glyphs
    /// is read as one word instead of glyph by glyph.
    var speakingSpoilerMasks: String {
        let mask = FormattedString.spoilerMask
        guard contains(mask) else { return self }
        let name = L10n.string("Spoiler")
        var spoken = ""
        var previousIsMask = false
        for character in self {
            let isMask = character == mask
            if !isMask {
                spoken.append(character)
            } else if !previousIsMask {
                spoken += name
            }
            previousIsMask = isMask
        }
        return spoken
    }
}

// MARK: - AttributedString builder

extension FormattedString {
    private typealias UI = AttributeScopes.SwiftUIAttributes

    /// Build an AttributedString applying every entity to its UTF-16
    /// range. Entities whose offsets fall outside the text (corrupt
    /// stream, truncated string, etc.) are skipped instead of crashing.
    ///
    /// Attributes are set by their key type, as the spoiler is, not through
    /// the dynamic member key paths (`.font`): those key paths capture the
    /// attribute scopes, which are not Sendable.
    var attributedString: AttributedString {
        var attr = AttributedString(text)
        for entity in entities {
            guard let range = attr.utf16Range(offset: entity.offset, length: entity.length) else {
                continue
            }
            switch entity {
            case .bold:
                attr[range][UI.FontAttribute.self] = .body.bold()
            case .italic:
                attr[range][UI.FontAttribute.self] = .body.italic()
            case .code, .pre, .preCode:
                attr[range][UI.FontAttribute.self] = .body.monospaced()
                attr[range][UI.BackgroundColorAttribute.self] = .gray.opacity(0.18)
            case .underline:
                attr[range][UI.UnderlineStyleAttribute.self] = .single
            case .strikethrough:
                attr[range][UI.StrikethroughStyleAttribute.self] = .single
            case .spoiler:
                attr[range][WristSpoilerAttribute.self] = true
            case .blockQuote:
                attr[range][UI.BackgroundColorAttribute.self] = .gray.opacity(0.2)
            case .mention:
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                let raw = String(text.utf16Slice(offset: entity.offset, length: entity.length) ?? "")
                let handle = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
                if !handle.isEmpty,
                   let url = URL(string: "https://t.me/\(handle)") {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .mentionName(_, _, let userId):
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                if let url = URL(string: "tg://user?id=\(userId)") {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .url:
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                let raw = String(text.utf16Slice(offset: entity.offset, length: entity.length) ?? "")
                let urlString = raw.contains("://") ? raw : "https://\(raw)"
                if let url = URL(string: urlString) {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .textUrl(_, _, let href):
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                if let url = URL(string: href) {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .email:
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                let raw = String(text.utf16Slice(offset: entity.offset, length: entity.length) ?? "")
                if let url = URL(string: "mailto:\(raw)") {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .phone:
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
                let raw = String(text.utf16Slice(offset: entity.offset, length: entity.length) ?? "")
                let digits = raw.filter { "+0123456789".contains($0) }
                if let url = URL(string: "tel://\(digits)") {
                    attr[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
                }
            case .hashtag, .cashtag, .botCommand:
                attr[range][UI.ForegroundColorAttribute.self] = .accentColor
            case .customEmoji:
                // No watchOS custom-emoji renderer yet; the underlying
                // text glyph is the fallback Telegram itself ships.
                break
            }
        }
        return attr
    }
}

// MARK: - Custom AttributedString scopes

/// Marker attribute used to detect spoiler ranges when MessageTextView
/// decides whether to wrap the bubble in a tap-to-reveal overlay.
enum WristSpoilerAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "WristSpoiler"
}

// MARK: - UTF-16 indexing helpers

private extension AttributedString {
    func utf16Range(offset: Int, length: Int) -> Range<AttributedString.Index>? {
        guard offset >= 0, length > 0 else { return nil }
        let characters = self.characters
        let utf16 = String(characters).utf16
        guard offset <= utf16.count, offset + length <= utf16.count else { return nil }
        let plain = String(characters)
        guard
            let lo16 = plain.utf16.index(plain.utf16.startIndex, offsetBy: offset, limitedBy: plain.utf16.endIndex),
            let hi16 = plain.utf16.index(plain.utf16.startIndex, offsetBy: offset + length, limitedBy: plain.utf16.endIndex),
            let lo = lo16.samePosition(in: plain),
            let hi = hi16.samePosition(in: plain) else { return nil }
        let startOffset = plain.distance(from: plain.startIndex, to: lo)
        let endOffset = plain.distance(from: plain.startIndex, to: hi)
        let attrStart = self.index(self.startIndex, offsetByCharacters: startOffset)
        let attrEnd = self.index(self.startIndex, offsetByCharacters: endOffset)
        return attrStart..<attrEnd
    }
}

private extension String {
    func utf16Slice(offset: Int, length: Int) -> Substring? {
        guard offset >= 0, length > 0 else { return nil }
        let view = utf16
        guard offset + length <= view.count,
              let lo16 = view.index(view.startIndex, offsetBy: offset, limitedBy: view.endIndex),
            let hi16 = view.index(view.startIndex, offsetBy: offset + length, limitedBy: view.endIndex),
            let lo = lo16.samePosition(in: self),
            let hi = hi16.samePosition(in: self) else { return nil }
        return self[lo..<hi]
    }
}
