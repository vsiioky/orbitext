import Foundation

extension ChatStore {
    /// The rows of one list in TDLib's order: (order, chat id) descending.
    /// Each row carries that list's order and pin, the user's pending pin and
    /// mute, and the chat's typing state.
    func chats(in list: ChatListID) -> [ChatInfo] {
        guard let bucket = entries[list] else { return [] }
        var rows: [ChatInfo] = []
        rows.reserveCapacity(bucket.count)
        for (chatId, entry) in bucket where entry.isListed {
            guard let record = records[chatId] else { continue }
            rows.append(stamped(record, entry: entry, in: list))
        }
        rows.sort { ($0.order, $0.id) > ($1.order, $1.id) }
        return rows
    }

    /// One known chat, listed or not. It takes its place from `list` when the
    /// chat is listed there, else from Main, else it has none.
    func chat(id chatId: Int64, stampedFor list: ChatListID) -> ChatInfo? {
        guard let record = records[chatId] else { return nil }
        for candidate in [list, .main] {
            if let entry = entries[candidate]?[chatId], entry.isListed {
                return stamped(record, entry: entry, in: candidate)
            }
        }
        return stamped(record, entry: Entry(order: 0, isPinned: false, origin: .snapshot), in: list)
    }

    func isListed(_ chatId: Int64, in list: ChatListID) -> Bool {
        entries[list]?[chatId]?.isListed == true
    }

    private func stamped(_ record: ChatInfo, entry: Entry, in list: ChatListID) -> ChatInfo {
        var chat = record
        chat.order = entry.order
        chat.isPinned = pendingPins[list]?[record.id] ?? entry.isPinned
        if let isMuted = pendingMutes[record.id] {
            chat.isMuted = isMuted
        }
        if let typing = typing[record.id] {
            chat.typingUserNames = typing.names
            chat.typingActionKind = typing.kind
        }
        return chat
    }
}
