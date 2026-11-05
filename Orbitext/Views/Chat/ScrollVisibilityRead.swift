import Foundation
import SwiftUI

/// Dedup + filter logic for the per-message read-receipt-on-scroll path.
/// Extracted from ChatMessageListView so the
/// "should we send viewMessages for this message?" decision is testable
/// without standing up a SwiftUI view hierarchy.
///
/// Rules:
///   - outgoing messages already count as "read by us"; skip.
///   - already-read incoming messages have nothing to report; skip.
///   - each message is reported at most once per chat-open. The caller
///     owns the `sent` set and clears it when the chat closes, so a
///     subsequent open reports again (TDLib dedups server-side anyway,
///     but we avoid burning a throttle slot per micro-scroll).
enum ScrollVisibilityRead {
    /// Returns true iff the message should be marked read AND records
    /// it in `sent` so a later visibility flicker on the same row is
    /// a no-op.
    static func shouldMark(message: MessageInfo, sent: inout Set<Int64>) -> Bool {
        guard !message.isOutgoing, !message.isRead else { return false }
        return sent.insert(message.id).inserted
    }

    /// Album variant: returns the subset of `album.messages` that
    /// still need a viewMessages call. Each message is filtered through
    /// `shouldMark` so outgoing / already-read / already-sent siblings
    /// are silently dropped. Order matches album order.
    static func messagesToMark(album: MessageAlbumInfo, sent: inout Set<Int64>) -> [Int64] {
        var out: [Int64] = []
        for msg in album.messages {
            if shouldMark(message: msg, sent: &sent) {
                out.append(msg.id)
            }
        }
        return out
    }
}

/// Mutable per-chat-open state for scroll-driven read receipts. Keeps the
/// SwiftUI list from knowing how dedupe/filtering works.
struct ScrollVisibilityReadCoordinator {
    private var sentMessageIds: Set<Int64> = []

    mutating func messageIdToMark(_ message: MessageInfo) -> Int64? {
        guard ScrollVisibilityRead.shouldMark(message: message, sent: &sentMessageIds) else { return nil }
        return message.id
    }

    mutating func messageIdsToMark(_ album: MessageAlbumInfo) -> [Int64] {
        ScrollVisibilityRead.messagesToMark(album: album, sent: &sentMessageIds)
    }
}

/// Attaches `.onScrollVisibilityChange` to a single message row when the
/// runtime is watchOS 11+. On watchOS 10 the modifier is unavailable, so
/// we degrade silently to the existing "mark whole chat read on open"
/// path that `ChatRepository.markAsRead` already covers.
struct MessageVisibilityReadModifier: ViewModifier {
    let message: MessageInfo
    let chatId: Int64
    let repository: ChatRepository
    @Binding var coordinator: ScrollVisibilityReadCoordinator

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollVisibilityChange(threshold: 0.5) { visible in
                guard visible, let messageId = coordinator.messageIdToMark(message) else { return }
                Task { await repository.markMessageAsRead(chatId: chatId, messageId: messageId) }
            }
        } else {
            content
        }
    }
}

/// Album counterpart of `MessageVisibilityReadModifier`. Reports each
/// incoming, unread album member through `markMessageAsRead` so the
/// sender sees per-photo read receipts (TDLib treats album messages as
/// independent rows on the protocol level even though we render them
/// as one bubble).
struct AlbumVisibilityReadModifier: ViewModifier {
    let album: MessageAlbumInfo
    let chatId: Int64
    let repository: ChatRepository
    @Binding var coordinator: ScrollVisibilityReadCoordinator

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollVisibilityChange(threshold: 0.5) { visible in
                guard visible else { return }
                let ids = coordinator.messageIdsToMark(album)
                guard !ids.isEmpty else { return }
                Task {
                    for id in ids {
                        await repository.markMessageAsRead(chatId: chatId, messageId: id)
                    }
                }
            }
        } else {
            content
        }
    }
}
