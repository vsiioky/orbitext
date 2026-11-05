import Foundation

/// The app's copy of TDLib's chat lists: one record per chat it has heard of,
/// and each chat's place (order and pin) in each list.
///
/// TDLib keeps its own chat objects and positions and reports every change as
/// an update, so the store follows the updates and treats everything else as a
/// snapshot of an older moment: a page of `getChats`, a row restored from
/// disk, a fetched chat. A snapshot never overrides what an update said in
/// this session, and never rolls a record back past a change made after the
/// snapshot was requested.
///
/// A pure value type with no I/O. The repository owns the one instance and
/// mutates it in place, on the main actor.
struct ChatStore {
    /// A chat's place in one list.
    struct Entry: Equatable {
        enum Origin: Equatable {
            /// TDLib reported it in this session: authoritative.
            case update
            /// From disk, a page, a fetched chat, or an earlier session: it
            /// yields to updates and to tombstones.
            case snapshot
        }

        let order: Int64
        let isPinned: Bool
        let origin: Origin

        /// TDLib said the chat is not in the list. Kept so that an older page
        /// or file cannot bring the row back.
        var isTombstone: Bool {
            origin == .update && order == 0
        }

        /// A snapshot row counts even with order 0: that may only mean the
        /// positions have not arrived yet.
        var isListed: Bool {
            order > 0 || origin == .snapshot
        }
    }

    struct Typing: Equatable {
        let names: [String]
        let kind: ChatActionKind
    }

    /// What a write touched, so the caller can refresh only what is on screen.
    struct Change: Equatable {
        /// Lists whose entries changed.
        var lists: Set<ChatListID> = []
        /// Chats whose record, typing state or overlay changed.
        var chatIds: Set<Int64> = []
        /// Chats that were just tombstoned, by list.
        var tombstoned: [ChatListID: Set<Int64>] = [:]

        var isEmpty: Bool {
            lists.isEmpty && chatIds.isEmpty
        }

        mutating func formUnion(_ other: Change) {
            lists.formUnion(other.lists)
            chatIds.formUnion(other.chatIds)
            tombstoned.merge(other.tombstoned) { $0.union($1) }
        }
    }

    /// Where a batch of rows comes from, which decides what it may overwrite.
    enum SnapshotMode: Equatable {
        /// The cache file read at launch. Fills gaps only and is not news.
        case restore
        /// A `getChats` page requested at revision `since`. With
        /// `replacingSnapshots`, snapshot entries the page does not return
        /// leave the list. With `isCompletePrefix` the page is the top of the
        /// list exactly, as a complete Main page is (its rows carry Main's
        /// order), so snapshot entries inside its range that it does not
        /// return leave too: TDLib would have returned them.
        case page(since: UInt64, replacingSnapshots: Bool, isCompletePrefix: Bool = false)
        /// A chat fetched because a message arrived for one the list lacks.
        /// May put it into Main, if Main says it is there.
        case fetched(since: UInt64)
        /// A chat fetched to look it up. Fills the directory, never a list.
        case directory(since: UInt64)
        /// The rows replace the list exactly. For tests and previews.
        case seed
    }

    /// Fields of every known chat, with `order` 0, `isPinned` false and no
    /// typing state: those belong to a list or to the moment.
    private(set) var records: [Int64: ChatInfo] = [:]
    private(set) var entries: [ChatListID: [Int64: Entry]] = [:]
    private(set) var typing: [Int64: Typing] = [:]
    /// Pin and mute the user asked for, shown until TDLib answers.
    private(set) var pendingPins: [ChatListID: [Int64: Bool]] = [:]
    private(set) var pendingMutes: [Int64: Bool] = [:]
    /// Bumped by every write except `.restore`. A snapshot requested at
    /// revision R may only replace records last written at R or before.
    private(set) var revision: UInt64 = 0
    private var recordRevision: [Int64: UInt64] = [:]

    // MARK: - Fields

    /// Fields of a chat as a snapshot of TDLib's mirror. The mirror knows only
    /// Main, so this never creates, removes or reorders an entry, with one
    /// exception: a snapshot Main entry follows the mirror's positive order.
    /// The record is stamped even when nothing differs, but the change is
    /// empty then: TDLib repeats fields it has not changed, for example a
    /// contact's online status for a chat nobody lists.
    mutating func applyFields(_ chat: ChatInfo) -> Change {
        revision &+= 1
        var change = Change()
        if writeRecord(chat, stamping: true) {
            change.chatIds.insert(chat.id)
        }
        if chat.order > 0, let entry = entries[.main]?[chat.id], entry.origin == .snapshot {
            let refreshed = Entry(order: chat.order, isPinned: chat.isPinned, origin: .snapshot)
            if refreshed != entry {
                entries[.main]?[chat.id] = refreshed
                change.lists.insert(.main)
                change.chatIds.insert(chat.id)
            }
        }
        if pendingMutes[chat.id] == chat.isMuted {
            pendingMutes[chat.id] = nil
            change.chatIds.insert(chat.id)
        }
        return change
    }

    /// Changes a known chat's fields in place. Unknown chats are left alone.
    mutating func updateRecord(_ chatId: Int64, _ mutate: (inout ChatInfo) -> Void) -> Change {
        guard var record = records[chatId] else { return Change() }
        revision &+= 1
        mutate(&record)
        records[chatId] = record
        recordRevision[chatId] = revision
        return Change(chatIds: [chatId])
    }

    // MARK: - Positions

    mutating func applyPositions(_ update: ChatPositionUpdate) -> Change {
        var change = applyFields(update.chat)
        let chatId = update.chat.id
        switch update.source {
        case .explicitPosition:
            for position in update.positions {
                change.formUnion(setUpdateEntry(position, chatId: chatId))
            }
        case .positionsReplacement:
            for position in update.positions {
                change.formUnion(setUpdateEntry(position, chatId: chatId))
            }
            // The vector is the chat's whole truth: a list that TDLib put the
            // chat into this session, and that is missing from it, has lost
            // the chat. A snapshot says nothing about this session.
            let named = Set(update.positions.map(\.list))
            let lost = entries.compactMap { list, bucket -> ChatListID? in
                guard !named.contains(list), let entry = bucket[chatId],
                      entry.origin == .update, entry.order > 0 else { return nil }
                return list
            }
            for list in lost {
                change.formUnion(setUpdateEntry(ChatListPosition(list: list, order: 0, isPinned: false), chatId: chatId))
            }
        case .newChat:
            for position in update.positions where position.order > 0 {
                change.formUnion(setUpdateEntry(position, chatId: chatId))
            }
        }
        change.formUnion(retireExcludedList(by: update.positions, chatId: chatId))
        clearConfirmedPins(chatId: chatId)
        return change
    }

    /// A chat is in Main or in the archive, never in both: a positive position
    /// in one retires the other, even when that is only a snapshot (a row
    /// restored from disk, or one an earlier client reported) that TDLib will
    /// never mention again. Main is tombstoned even when it has no entry, so
    /// that a page requested before the move cannot bring the chat back; no
    /// page lists the archive, so it only needs retiring when it holds one.
    private mutating func retireExcludedList(by positions: [ChatListPosition], chatId: Int64) -> Change {
        var change = Change()
        for position in positions where position.order > 0 {
            let excluded: ChatListID
            switch position.list {
            case .main: excluded = .archive
            case .archive: excluded = .main
            case .folder: continue
            }
            let named = positions.contains { $0.list == excluded && $0.order > 0 }
            if named || (excluded != .main && entries[excluded]?[chatId] == nil) { continue }
            change.formUnion(setUpdateEntry(ChatListPosition(list: excluded, order: 0, isPinned: false), chatId: chatId))
        }
        return change
    }

    private mutating func setUpdateEntry(_ position: ChatListPosition, chatId: Int64) -> Change {
        let new = Entry(order: position.order, isPinned: position.order > 0 && position.isPinned, origin: .update)
        let old = entries[position.list]?[chatId]
        guard old != new else { return Change() }
        entries[position.list, default: [:]][chatId] = new
        var change = Change(lists: [position.list])
        if new.isTombstone {
            change.tombstoned[position.list] = [chatId]
        }
        return change
    }

    private mutating func clearConfirmedPins(chatId: Int64) {
        for (list, pins) in pendingPins {
            guard let pending = pins[chatId],
                  let entry = entries[list]?[chatId],
                  entry.origin == .update, entry.isPinned == pending else { continue }
            removePendingPin(chatId, in: list)
        }
    }

    // MARK: - Snapshots

    mutating func applySnapshot(_ rows: [ChatInfo], in list: ChatListID, mode: SnapshotMode) -> Change {
        var change = Change()
        if mode != .restore {
            revision &+= 1
        }
        for row in rows where acceptsRecord(row.id, mode: mode) {
            writeRecord(row, stamping: mode != .restore)
            change.chatIds.insert(row.id)
        }
        switch mode {
        case .restore:
            change.formUnion(placeSnapshotRows(rows, in: list))
        case .page(let since, let replacingSnapshots, let isCompletePrefix):
            change.formUnion(placeSnapshotRows(rows, in: list))
            let returnedIds = Set(rows.map(\.id))
            var stale: [Int64] = []
            if replacingSnapshots {
                stale = snapshotIds(in: list) { id, _ in !returnedIds.contains(id) }
            } else if isCompletePrefix, let floor = lowestPosition(of: rows) {
                // The page is the top of the list: a snapshot that ranks in it,
                // and that TDLib did not return, is not there any more. One
                // changed after the request may be news the page predates.
                stale = snapshotIds(in: list) { id, entry in
                    !returnedIds.contains(id)
                        && (entry.order, id) >= floor
                        && recordRevision[id, default: 0] <= since
                }
            }
            change.formUnion(removeEntries(stale, in: list))
        case .fetched:
            if list == .main {
                change.formUnion(placeFetchedRows(rows))
            }
        case .directory:
            break
        case .seed:
            change.formUnion(seed(rows, in: list))
        }
        return change
    }

    private func acceptsRecord(_ chatId: Int64, mode: SnapshotMode) -> Bool {
        switch mode {
        case .seed:
            return true
        case .restore:
            return records[chatId] == nil
        case .page(let since, _, _), .fetched(let since), .directory(let since):
            return records[chatId] == nil || recordRevision[chatId, default: 0] <= since
        }
    }

    /// A page or file row sets a snapshot entry, unless TDLib already spoke
    /// about the chat in this list. Order 0 on a row says nothing yet.
    private mutating func placeSnapshotRows(_ rows: [ChatInfo], in list: ChatListID) -> Change {
        var change = Change()
        for row in rows {
            let existing = entries[list]?[row.id]
            if existing?.origin == .update { continue }
            let entry: Entry
            if row.order > 0 {
                entry = Entry(order: row.order, isPinned: row.isPinned, origin: .snapshot)
            } else if existing == nil {
                entry = Entry(order: 0, isPinned: false, origin: .snapshot)
            } else {
                continue
            }
            if entry != existing {
                entries[list, default: [:]][row.id] = entry
                change.lists.insert(list)
            }
        }
        return change
    }

    private func snapshotIds(in list: ChatListID, where isStale: (_ chatId: Int64, _ entry: Entry) -> Bool) -> [Int64] {
        (entries[list] ?? [:]).filter { $0.value.origin == .snapshot && isStale($0.key, $0.value) }.map(\.key)
    }

    private mutating func removeEntries(_ chatIds: [Int64], in list: ChatListID) -> Change {
        guard !chatIds.isEmpty else { return Change() }
        for chatId in chatIds {
            entries[list]?[chatId] = nil
        }
        return Change(lists: [list])
    }

    /// Where a page ends: the (order, id) of its lowest row. Nil if the page
    /// is empty or a row has no order yet, so the page has no known range.
    private func lowestPosition(of rows: [ChatInfo]) -> (Int64, Int64)? {
        guard !rows.isEmpty, rows.allSatisfy({ $0.order > 0 }) else { return nil }
        return rows.map { ($0.order, $0.id) }.min { $0 < $1 }
    }

    /// A fetched chat is in Main only if Main has a positive order for it and
    /// TDLib has not said otherwise: an archived chat fetched for a new
    /// message has order 0 and stays where it is.
    private mutating func placeFetchedRows(_ rows: [ChatInfo]) -> Change {
        var change = Change()
        for row in rows where row.order > 0 {
            let existing = entries[.main]?[row.id]
            if existing?.origin == .update { continue }
            let entry = Entry(order: row.order, isPinned: row.isPinned, origin: .snapshot)
            if entry != existing {
                entries[.main, default: [:]][row.id] = entry
                change.lists.insert(.main)
            }
        }
        return change
    }

    private mutating func seed(_ rows: [ChatInfo], in list: ChatListID) -> Change {
        var bucket: [Int64: Entry] = [:]
        for row in rows {
            bucket[row.id] = Entry(order: row.order, isPinned: row.isPinned, origin: .snapshot)
            typing[row.id] = row.typingUserNames.isEmpty
                ? nil : Typing(names: row.typingUserNames, kind: row.typingActionKind)
        }
        entries[list] = bucket
        return Change(lists: [list], chatIds: Set(rows.map(\.id)))
    }

    /// A new TDLib client has to confirm membership again: what the last one
    /// reported becomes a snapshot. Tombstones stay, so that a page from the
    /// same account cannot undo a removal already observed.
    mutating func beginSession() {
        for (list, bucket) in entries {
            for (id, entry) in bucket where entry.origin == .update && entry.order > 0 {
                entries[list]?[id] = Entry(order: entry.order, isPinned: entry.isPinned, origin: .snapshot)
            }
        }
    }

    // MARK: - Typing and overlays

    /// An empty `names` clears the chat's typing state.
    mutating func setTyping(_ chatId: Int64, names: [String], kind: ChatActionKind) -> Change {
        let new = names.isEmpty ? nil : Typing(names: names, kind: kind)
        guard typing[chatId] != new else { return Change() }
        typing[chatId] = new
        return Change(chatIds: [chatId])
    }

    mutating func clearTyping(_ chatIds: Set<Int64>) -> Change {
        let cleared = chatIds.filter { typing[$0] != nil }
        for chatId in cleared {
            typing[chatId] = nil
        }
        return Change(chatIds: cleared)
    }

    /// Shows a pin that was asked for until an update of that list agrees with
    /// it. Nil removes the overlay, for a request that failed.
    mutating func setPendingPin(_ chatId: Int64, in list: ChatListID, to isPinned: Bool?) -> Change {
        if let isPinned {
            pendingPins[list, default: [:]][chatId] = isPinned
        } else {
            removePendingPin(chatId, in: list)
        }
        return Change(chatIds: [chatId])
    }

    /// Shows a mute that was asked for until a snapshot of the chat agrees
    /// with it. Nil removes the overlay, for a request that failed.
    mutating func setPendingMute(_ chatId: Int64, to isMuted: Bool?) -> Change {
        pendingMutes[chatId] = isMuted
        return Change(chatIds: [chatId])
    }

    private mutating func removePendingPin(_ chatId: Int64, in list: ChatListID) {
        pendingPins[list]?[chatId] = nil
        if pendingPins[list]?.isEmpty == true {
            pendingPins[list] = nil
        }
    }

    // MARK: - Records

    /// `stamping` marks the record as written now, which makes older
    /// snapshots unable to replace it. Returns whether the record differs
    /// from the one it replaced. `ChatInfo ==` compares only the id of the
    /// last message, and a message edit keeps its id.
    @discardableResult
    private mutating func writeRecord(_ chat: ChatInfo, stamping: Bool) -> Bool {
        var record = chat
        record.order = 0
        record.isPinned = false
        record.typingUserNames = []
        record.typingActionKind = .none
        let previous = records[chat.id]
        records[chat.id] = record
        if stamping {
            recordRevision[chat.id] = revision
        }
        guard let previous else { return true }
        return previous != record || previous.lastMessage != record.lastMessage
    }
}
