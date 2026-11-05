import Foundation

/// Bounded chat action state. The service owns synchronization and event delivery.
struct ChatActionState {
    struct Snapshot: Equatable {
        let names: [String]
        let kind: ChatActionKind
    }

    private struct Entry {
        var users: [Int64: String]
        var lastKind: ChatActionKind
        var lastSeen: ContinuousClock.Instant
    }

    private var entries: [Int64: Entry] = [:]
    private let capacity = 50

    /// Unknown actions are ignored; only an explicit cancel removes a sender.
    mutating func apply(
        chatId: Int64,
        senderId: Int64,
        name: String,
        actionType: String,
        at instant: ContinuousClock.Instant = .now
    ) -> Snapshot? {
        let kind = ChatActionKind(tdlibType: actionType)
        guard kind != .none || actionType == "chatActionCancel" else { return nil }

        if actionType == "chatActionCancel" {
            if var entry = entries[chatId] {
                entry.users.removeValue(forKey: senderId)
                // A partial cancellation preserves the last action kind and recency.
                entries[chatId] = entry.users.isEmpty ? nil : entry
            }
        } else {
            var entry = entries[chatId] ?? Entry(users: [:], lastKind: kind, lastSeen: instant)
            entry.users[senderId] = name
            entry.lastKind = kind
            entry.lastSeen = instant
            entries[chatId] = entry

            if entries.count > capacity {
                let candidates = entries
                    .filter { $0.key != chatId }
                    .sorted { $0.value.lastSeen < $1.value.lastSeen }
                    .prefix(entries.count - capacity)
                for (key, _) in candidates {
                    entries.removeValue(forKey: key)
                }
            }
        }

        return snapshot(for: chatId)
    }

    func snapshot(for chatId: Int64) -> Snapshot {
        guard let entry = entries[chatId] else {
            return Snapshot(names: [], kind: .none)
        }
        return Snapshot(names: Array(entry.users.values), kind: entry.lastKind)
    }

    mutating func reset() {
        entries.removeAll()
    }
}
