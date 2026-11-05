import Foundation

// MARK: - ReactionInfo from typed TDApi

extension ReactionInfo {
    /// Nil for a reaction kind newer than the schema, and for an emoji
    /// reaction without an emoji.
    init?(tdApi reaction: TDApi.MessageReaction) {
        let count = Int(reaction.totalCount)
        let isSelected = reaction.isChosen
        switch reaction.type {
        case .reactionTypeEmoji(let emoji)?:
            guard !emoji.emoji.isEmpty else { return nil }
            let normalizedEmoji = emoji.emoji.normalizedReactionEmoji
            self.init(
                key: "emoji:\(normalizedEmoji)",
                emoji: emoji.emoji,
                actionValue: normalizedEmoji,
                count: count,
                isSelected: isSelected
            )
        case .reactionTypePaid?:
            self.init(key: "paid", emoji: "⭐", actionValue: nil, count: count, isSelected: isSelected)
        case .reactionTypeCustomEmoji(let custom)?:
            self.init(
                key: "custom:\(custom.customEmojiId)",
                emoji: "✨",
                actionValue: nil,
                count: count,
                isSelected: isSelected
            )
        case .unknown?, nil:
            return nil
        }
    }

    /// The reactions a message shows: mapped, the ones the user chose first,
    /// then by count, then by key so the order does not jump between updates.
    static func list(tdApi reactions: [TDApi.MessageReaction]) -> [ReactionInfo] {
        reactions
            .compactMap(ReactionInfo.init(tdApi:))
            .sorted { lhs, rhs in
                if lhs.isSelected != rhs.isSelected {
                    return lhs.isSelected && !rhs.isSelected
                }
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.key < rhs.key
            }
    }
}
