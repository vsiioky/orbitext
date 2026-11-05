import Foundation

/// Encapsulates the retry and pagination logic for loading chat messages.
/// Keeps ChatView focused on presentation by moving async loading details here.
enum MessageLoadingHelper {
    struct InitialLoadResult {
        var messages: [MessageInfo]
        var scrollToViewID: String?
    }

    struct OlderLoadResult {
        var newMessages: [MessageInfo]
        var hasMore: Bool
    }

    // MARK: - Initial load with retry

    /// Loads messages for a chat, retrying empty initial results and giving
    /// suspiciously short non-empty local history one warm-up retry. TDLib can
    /// briefly return only the latest locally available message right after
    /// openChat; taking that as authoritative strands the user on a one-message
    /// page until manual pagination.
    static func loadInitial(
        chatId: Int64,
        scrollToMessageId: Int64?,
        messageManager: MessageManager,
        chatRepository: ChatRepository
    ) async -> InitialLoadResult {
        var loaded = await messageManager.loadMessages(chatId: chatId)

        for attempt in 1...AppConstants.Message.loadRetryCount where loaded.isEmpty {
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(AppConstants.Message.retryBaseDelay * attempt))
            guard !Task.isCancelled else { break }
            let retry = await messageManager.loadMessages(chatId: chatId)
            if !retry.isEmpty {
                loaded = retry
            }
        }

        loaded = await expandShortInitialLoad(
            loaded,
            chatId: chatId,
            messageManager: messageManager
        )

        guard !Task.isCancelled else {
            return InitialLoadResult(messages: [], scrollToViewID: nil)
        }

        var messages = Array(loaded.reversed())

        // If a target message is requested but not in the recent batch, load around it
        if let targetId = scrollToMessageId, !messages.contains(where: { $0.id == targetId }) {
            let around = await messageManager.loadMessages(chatId: chatId, fromMessageId: targetId)
            if !around.isEmpty {
                let chronological = Array(around.reversed())
                let existingIds = Set(messages.map(\.id))
                let newMessages = chronological.filter { !existingIds.contains($0.id) }
                messages.insert(contentsOf: newMessages, at: 0)
            }
        }

        // Mark as read
        if let lastMsg = messages.last {
            await chatRepository.markAsRead(chatId: chatId, messageId: lastMsg.id)
        }

        // Determine scroll target.
        //
        // ChatMessageListView groups consecutive messages with the same
        // non-zero `mediaAlbumId` into a single album bubble whose SwiftUI
        // .id is "album:<albumId>" (not the individual messages' viewIDs).
        // If we hand `proxy.scrollTo(message.viewID)` for a message that's
        // part of an album, the ScrollViewProxy can't find that id and the
        // list stays at its current position (typically the top after
        // .task reset). Compute the rendered ChatItem id instead.
        //
        // ChatItem.id matches the .id() values used in ChatMessageListView:
        //   - .message(m) -> m.viewID
        //   - .album(a)   -> "album:<a.albumId>"
        let scrollToViewID: String? = {
            if let targetId = scrollToMessageId,
               let target = messages.first(where: { $0.id == targetId }) {
                if target.mediaAlbumId != 0 {
                    return "album:\(target.mediaAlbumId)"
                }
                return target.viewID
            }
            guard let last = messages.last else { return nil }
            if last.mediaAlbumId != 0 {
                // Only collapse to an album bubble if there is more than one
                // sibling in the loaded window - matches MessageAlbumInfo
                // .group's lone-survivor fallback (a stale media_album_id
                // on a single message still renders as .message).
                let siblings = messages.filter { $0.mediaAlbumId == last.mediaAlbumId }
                if siblings.count > 1 {
                    return "album:\(last.mediaAlbumId)"
                }
            }
            return last.viewID
        }()

        return InitialLoadResult(messages: messages, scrollToViewID: scrollToViewID)
    }

    private static func expandShortInitialLoad(
        _ initial: [MessageInfo],
        chatId: Int64,
        messageManager: MessageManager
    ) async -> [MessageInfo] {
        var loaded = initial
        guard !loaded.isEmpty, loaded.count < AppConstants.Message.minMessageCount, !Task.isCancelled else { return loaded }
        try? await Task.sleep(for: .milliseconds(AppConstants.Message.retryBaseDelay))
        guard !Task.isCancelled else { return loaded }

        let retry = await messageManager.loadMessages(chatId: chatId)
        if retry.count > loaded.count {
            loaded = retry
        }

        guard loaded.count < AppConstants.Message.minMessageCount,
              let oldestLoadedId = loaded.last?.id else {
            return loaded
        }

        let older = await messageManager.loadMessages(
            chatId: chatId,
            fromMessageId: oldestLoadedId,
            limit: AppConstants.Message.defaultLoadLimit
        )
        return mergeReverseChronologicalMessages(loaded, withOlder: older)
    }

    private static func mergeReverseChronologicalMessages(
        _ loaded: [MessageInfo],
        withOlder older: [MessageInfo]
    ) -> [MessageInfo] {
        guard !older.isEmpty else { return loaded }

        var seenIds = Set(loaded.map(\.id))
        var merged = loaded
        for message in older where !seenIds.contains(message.id) {
            merged.append(message)
            seenIds.insert(message.id)
        }
        return merged
    }

    // MARK: - Older messages (pagination)

    /// Loads messages older than `anchorMessageId`. Returns the new messages to
    /// prepend and whether more pages are expected.
    static func loadOlder(
        chatId: Int64,
        anchorMessageId: Int64,
        existingIds: Set<Int64>,
        messageManager: MessageManager
    ) async -> OlderLoadResult {
        let older = await messageManager.loadMessages(chatId: chatId, fromMessageId: anchorMessageId)

        guard !Task.isCancelled else {
            return OlderLoadResult(newMessages: [], hasMore: true)
        }

        if older.isEmpty {
            return OlderLoadResult(newMessages: [], hasMore: false)
        }

        let chronological = older.reversed()
        let newMessages = chronological.filter { !existingIds.contains($0.id) }

        return OlderLoadResult(
            newMessages: newMessages,
            hasMore: !newMessages.isEmpty
        )
    }
}
