import Foundation
import os
import WidgetKit

extension ChatRepository {
    // MARK: - Load

    func loadChats() async {
        let totalStart = ContinuousClock.now
        guard chatListLoadingState == .idle else {
            Logger.app.debug("loadChats skipped: already loading")
            return
        }
        let activeFolderId = activeFolderId
        let generation = chatListGeneration
        let scopeChanged = displayedListID.folderId != activeFolderId
        let restoredScopeCache: Bool
        if scopeChanged {
            restoredScopeCache = restoreCachedChats(for: activeFolderId)
        } else {
            restoredScopeCache = false
        }
        let loadingState: ChatListLoadingState = chats.isEmpty ? .initial : .refresh
        chatListLoadingState = loadingState
        defer { if generation == chatListGeneration { chatListLoadingState = .idle } }
        do {
            chatLoadLimit = max(chatLoadLimit, AppConstants.Chat.loadLimit)
            let loadLimit = chatLoadLimit
            let initialSyncComplete = isInitialSyncComplete
            let existingChatCount = chats.count
            Logger.app.debug(
                "loadChats started: limit=\(loadLimit) folder=\(String(describing: activeFolderId), privacy: .public) initialSync=\(initialSyncComplete) existingChats=\(existingChatCount)"
            )
            let serviceStart = ContinuousClock.now
            let since = store.revision
            let page = try await service.getChatPage(limit: chatLoadLimit, folderId: activeFolderId)
            let loaded = page.chats
            let serviceElapsed = ContinuousClock.now - serviceStart
            guard !Task.isCancelled, generation == chatListGeneration, activeFolderId == self.activeFolderId else {
                Logger.app.debug("loadChats cancelled before applying loaded chats")
                return
            }
            folderListConfirmedByClient = activeFolderId
            let applyStart = ContinuousClock.now
            let previousCount = chats.count
            // getChats is an informational prefix, not an authoritative full
            // snapshot. Main-list removals come from position updates; a
            // complete Main page only retires the snapshot rows it outranks.
            let keepMissingExisting = (!scopeChanged || restoredScopeCache) &&
                (activeFolderId == nil || loaded.count < previousCount)
            applyPage(
                loaded, isComplete: page.isComplete, folderId: activeFolderId, since: since,
                replacingSnapshots: !keepMissingExisting
            )
            let applyElapsed = ContinuousClock.now - applyStart
            let cacheStart = ContinuousClock.now
            saveChatsToCache()
            let cacheElapsed = ContinuousClock.now - cacheStart
            canLoadMoreChats = loaded.count >= chatLoadLimit || chats.count > loaded.count
            isInitialSyncComplete = true
            notificationManager.hasLaunchedBefore = true
            let canLoadMore = canLoadMoreChats
            Logger.app.debug(
                "loadChats completed: loaded=\(loaded.count) total=\(self.chats.count) keepMissing=\(keepMissingExisting) canLoadMore=\(canLoadMore) folder=\(String(describing: activeFolderId), privacy: .public)"
            )
            lastPaginationTime = Date()
            let widgetStart = ContinuousClock.now
            widgetSync.update(chats: filteredChats, isInBackground: isInBackground)
            let widgetElapsed = ContinuousClock.now - widgetStart
            Logger.app.debug(
                "loadChats timing: service=\(serviceElapsed, privacy: .public) apply=\(applyElapsed, privacy: .public) cache=\(cacheElapsed, privacy: .public) widget=\(widgetElapsed, privacy: .public) total=\(ContinuousClock.now - totalStart, privacy: .public) restoredCache=\(restoredScopeCache) scopeChanged=\(scopeChanged) folder=\(String(describing: activeFolderId), privacy: .public)"
            )
            prepareNextChatPageIfNeeded()
        } catch {
            Logger.app.error("loadChats failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMoreChats() async {
        let totalStart = ContinuousClock.now
        guard canLoadMoreChats,
              chatListLoadingState == .idle,
              Date().timeIntervalSince(lastPaginationTime) > AppConstants.Chat.paginationThrottle else { return }
        chatListLoadingState = .pagination
        let generation = chatListGeneration
        defer { if generation == chatListGeneration { chatListLoadingState = .idle } }
        lastPaginationTime = Date()
        chatLoadLimit += AppConstants.Chat.loadLimit
        do {
            let activeFolderId = activeFolderId
            let requestedLimit = chatLoadLimit
            Logger.app.debug(
                "loadMoreChats started: current=\(self.chats.count) requested=\(requestedLimit) folder=\(String(describing: activeFolderId), privacy: .public)"
            )
            let serviceStart = ContinuousClock.now
            let loaded: [ChatInfo]
            let isComplete: Bool
            let since: UInt64
            if let prefetched = try await prefetchedPage(for: activeFolderId, limit: requestedLimit) {
                loaded = prefetched.chats
                isComplete = prefetched.isComplete
                since = prefetched.startedAtRevision
            } else {
                since = store.revision
                let page = try await service.getChatPage(limit: requestedLimit, folderId: activeFolderId)
                loaded = page.chats
                isComplete = page.isComplete
            }
            let serviceElapsed = ContinuousClock.now - serviceStart
            guard !Task.isCancelled, generation == chatListGeneration, activeFolderId == self.activeFolderId else {
                Logger.app.debug("loadMoreChats cancelled before applying loaded chats")
                return
            }
            folderListConfirmedByClient = activeFolderId
            let applyStart = ContinuousClock.now
            let previousCount = chats.count
            let keepMissingExisting = activeFolderId == nil || loaded.count < previousCount
            applyPage(
                loaded, isComplete: isComplete, folderId: activeFolderId, since: since,
                replacingSnapshots: !keepMissingExisting
            )
            let applyElapsed = ContinuousClock.now - applyStart
            let cacheStart = ContinuousClock.now
            saveChatsToCache()
            let cacheElapsed = ContinuousClock.now - cacheStart
            canLoadMoreChats = loaded.count >= requestedLimit || chats.count > loaded.count
            Logger.app.debug("loadMoreChats reconciled: previous=\(previousCount) requested=\(requestedLimit) loaded=\(loaded.count) total=\(self.chats.count) keepMissing=\(keepMissingExisting) canLoadMore=\(self.canLoadMoreChats)")
            let widgetStart = ContinuousClock.now
            widgetSync.update(chats: filteredChats, isInBackground: isInBackground)
            let widgetElapsed = ContinuousClock.now - widgetStart
            Logger.app.debug(
                "loadMoreChats timing: service=\(serviceElapsed, privacy: .public) apply=\(applyElapsed, privacy: .public) cache=\(cacheElapsed, privacy: .public) widget=\(widgetElapsed, privacy: .public) total=\(ContinuousClock.now - totalStart, privacy: .public) folder=\(String(describing: activeFolderId), privacy: .public)"
            )
            prepareNextChatPageIfNeeded()
        } catch {
            Logger.app.debug("loadMoreChats error: \(error.localizedDescription)")
        }
    }

    func prepareNextChatPageIfNeeded() {
        guard canLoadMoreChats, isInitialSyncComplete, !chats.isEmpty else { return }
        let folderId = chatListPrefetchFolderId
        let nextLimit = max(chatLoadLimit, chats.count) + AppConstants.Chat.loadLimit

        if let page = prefetchedChatPage,
           page.folderId == folderId,
           page.limit >= nextLimit {
            return
        }
        if chatListPrefetchTargetFolderId == folderId,
           chatListPrefetchTargetLimit == nextLimit,
           chatListPrefetchTask != nil {
            return
        }

        chatListPrefetchTask?.cancel()
        prefetchedChatPage = nil
        chatListPrefetchTargetFolderId = folderId
        chatListPrefetchTargetLimit = nextLimit
        isPreparingNextChatPage = true

        let service = service
        let startedAtRevision = store.revision
        chatListPrefetchTask = Task { [weak self] in
            let start = ContinuousClock.now
            do {
                let answer = try await service.getChatPage(limit: nextLimit, folderId: folderId)
                guard !Task.isCancelled else { return nil }
                let chats = answer.chats
                let page = PrefetchedChatPage(
                    folderId: folderId, limit: nextLimit, chats: chats, isComplete: answer.isComplete,
                    startedAtRevision: startedAtRevision
                )
                Logger.app.debug(
                    "chatList prefetch completed: limit=\(nextLimit) loaded=\(chats.count) elapsed=\(ContinuousClock.now - start, privacy: .public) folder=\(String(describing: folderId), privacy: .public)"
                )
                await MainActor.run {
                    self?.finishChatListPrefetch(page, folderId: folderId, limit: nextLimit)
                }
                return page
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishChatListPrefetch(nil, folderId: folderId, limit: nextLimit)
                }
                return nil
            } catch {
                Logger.app.debug(
                    "chatList prefetch failed: limit=\(nextLimit) error=\(error.localizedDescription, privacy: .public) folder=\(String(describing: folderId), privacy: .public)"
                )
                await MainActor.run {
                    self?.finishChatListPrefetch(nil, folderId: folderId, limit: nextLimit)
                }
                return nil
            }
        }
        Logger.app.debug(
            "chatList prefetch started: limit=\(nextLimit) folder=\(String(describing: folderId), privacy: .public)"
        )
    }

    private func finishChatListPrefetch(_ page: PrefetchedChatPage?, folderId: Int64?, limit: Int) {
        guard chatListPrefetchTargetFolderId == folderId,
              chatListPrefetchTargetLimit == limit else { return }

        prefetchedChatPage = page
        if page != nil, let folderId, folderId == activeFolderId {
            // A cold start with a cached list loads the folder only here.
            folderListConfirmedByClient = folderId
        }
        chatListPrefetchTask = nil
        chatListPrefetchTargetFolderId = page == nil ? nil : folderId
        chatListPrefetchTargetLimit = page?.limit
        isPreparingNextChatPage = false
    }

    func invalidateChatListPrefetch() {
        chatListPrefetchTask?.cancel()
        chatListPrefetchTask = nil
        chatListPrefetchTargetFolderId = nil
        chatListPrefetchTargetLimit = nil
        prefetchedChatPage = nil
        isPreparingNextChatPage = false
    }

    /// Puts a page into the store and shows its list. A page is a snapshot: it
    /// fills in rows and fields TDLib has not updated since `since`, and with
    /// `replacingSnapshots` also drops snapshot rows it no longer returns. A
    /// complete Main page is the top of the list exactly, so it also drops
    /// the snapshot rows inside its range that it lacks.
    private func applyPage(
        _ loaded: [ChatInfo], isComplete: Bool, folderId: Int64?, since: UInt64, replacingSnapshots: Bool
    ) {
        let list = ChatListID(folderId: folderId)
        _ = store.applySnapshot(
            loaded.map(withLocalDraft),
            in: list,
            mode: .page(
                since: since, replacingSnapshots: replacingSnapshots,
                isCompletePrefix: isComplete && list == .main
            )
        )
        showList(list)
    }

    private func prefetchedPage(for folderId: Int64?, limit: Int) async throws -> PrefetchedChatPage? {
        if let page = prefetchedChatPage,
           page.folderId == folderId,
           page.limit >= limit {
            Logger.app.debug(
                "loadMoreChats using completed prefetch: requested=\(limit) prefetched=\(page.limit) folder=\(String(describing: folderId), privacy: .public)"
            )
            prefetchedChatPage = nil
            chatListPrefetchTargetFolderId = nil
            chatListPrefetchTargetLimit = nil
            return page
        }

        guard chatListPrefetchTargetFolderId == folderId,
              let targetLimit = chatListPrefetchTargetLimit,
              targetLimit >= limit,
              let task = chatListPrefetchTask else {
            return nil
        }

        Logger.app.debug(
            "loadMoreChats awaiting active prefetch: requested=\(limit) prefetch=\(targetLimit) folder=\(String(describing: folderId), privacy: .public)"
        )
        let page = await task.value
        chatListPrefetchTask = nil
        chatListPrefetchTargetFolderId = nil
        chatListPrefetchTargetLimit = nil
        prefetchedChatPage = nil
        isPreparingNextChatPage = false

        guard let page,
              page.folderId == folderId,
              page.limit >= limit else {
            return nil
        }

        Logger.app.debug(
            "loadMoreChats using awaited prefetch: requested=\(limit) prefetched=\(page.limit) loaded=\(page.chats.count) folder=\(String(describing: folderId), privacy: .public)"
        )
        return page
    }

    // MARK: - Folders

    func loadFolders() async {
        if !folders.isEmpty || isLoadingFolders { return }
        isLoadingFolders = true
        defer {
            isLoadingFolders = false
            didAttemptFolderLoad = true
        }
        do {
            let loadedFolders = try await service.getChatFolders()
            guard !Task.isCancelled else {
                Logger.app.debug("loadFolders cancelled before applying loaded folders")
                return
            }
            folders = loadedFolders
            reconcileFolderSelection()
            Logger.app.debug("loadFolders: \(self.folders.count) folders loaded via API")
            if folderFilterEnabled {
                syncWidget()
                prepareNextChatPageIfNeeded()
            }
        } catch {
            Logger.app.debug("loadFolders API unavailable, waiting for updateChatFolders")
        }
    }

    // MARK: - Chat Mutations

    /// Pins in the list on screen: each list keeps its own pinned chats. The
    /// pin is shown at once and kept until TDLib's position update for that
    /// list agrees, or the request fails.
    func pinChat(chatId: Int64, isPinned: Bool) async throws {
        let list = displayedListID
        publish(store.setPendingPin(chatId, in: list, to: isPinned), effects: .persist)
        do {
            try await performMutation(haptic: HapticManager.tap) {
                try await service.pinChat(chatId: chatId, in: list, isPinned: isPinned)
            }
        } catch {
            publish(store.setPendingPin(chatId, in: list, to: nil), effects: .persist)
            throw error
        }
    }

    /// The mute is shown at once and kept until a snapshot of the chat agrees,
    /// or the request fails.
    func muteChat(chatId: Int64, isMuted: Bool) async throws {
        publish(store.setPendingMute(chatId, to: isMuted), effects: .persist)
        do {
            try await performMutation(haptic: HapticManager.tap) {
                try await service.muteChat(chatId: chatId, isMuted: isMuted)
            }
        } catch {
            publish(store.setPendingMute(chatId, to: nil), effects: .persist)
            throw error
        }
    }

    /// Per-message read-receipt path used by the scroll-visibility
    /// observer. Unlike `markAsRead`, this does
    /// NOT short-circuit on `unreadCount == 0` and does NOT zero the
    /// local unread badge: TDLib's `updateChatReadInbox` reconciles
    /// the badge as the server advances `last_read_inbox_message_id`.
    /// We dedupe per `(chatId, messageId)` at repository level because
    /// SwiftUI can recreate row state while visibility callbacks are
    /// still firing. Scroll-driven receipts are debounced so a fast
    /// scroll sends one `viewMessages` vector per chat instead of a
    /// burst of one request per row cluster.
    func markMessageAsRead(chatId: Int64, messageId: Int64) async {
        enqueueReadReceiptIfNeeded(chatId: chatId, messageId: messageId)
    }

    func markAsRead(chatId: Int64, messageId: Int64) async {
        // Skip the service round-trip if we know the chat and it is already
        // fully read. MessageLoadingHelper.loadInitial calls
        // markAsRead on every chat open, including for chats whose
        // unreadCount is already 0; that wastes a throttle slot and a
        // Telegram round-trip per open. We only skip when we KNOW the
        // chat is read (TDLib announced it and it has unread == 0); for
        // chats we have not yet observed locally we forward the request
        // so initial-sync races still mark messages read on the server.
        if let chat = chat(id: chatId), chat.unreadCount == 0 {
            return
        }

        guard await sendReadReceiptIfNeeded(chatId: chatId, messageId: messageId) else {
            return
        }
        publish(store.updateRecord(chatId) { $0.unreadCount = 0 })
        saveChatsToCache()
        syncWidget()
    }

    private func sendReadReceiptIfNeeded(chatId: Int64, messageId: Int64) async -> Bool {
        if readReceiptMessageIdsByChat[chatId, default: []].contains(messageId) {
            return true
        }
        readReceiptMessageIdsByChat[chatId, default: []].insert(messageId)

        do {
            try await service.markAsRead(chatId: chatId, messageId: messageId)
            return true
        } catch {
            readReceiptMessageIdsByChat[chatId]?.remove(messageId)
            Logger.app.warning(
                "markAsRead failed for chat=\(chatId) msg=\(messageId): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// The user left the chat: the ids reported during the visit are
    /// forgotten, one per incoming message that scrolled into view. The
    /// visit's coordinator already dedupes within the visit, and the next
    /// visit reports what it shows again, as ScrollVisibilityRead describes;
    /// TDLib dedupes server-side. Ids still waiting for the flush stay
    /// queued and go out as planned.
    func releaseReadReceipts(chatId: Int64) {
        readReceiptMessageIdsByChat[chatId] = nil
    }

    private func enqueueReadReceiptIfNeeded(chatId: Int64, messageId: Int64) {
        if readReceiptMessageIdsByChat[chatId, default: []].contains(messageId) {
            return
        }
        readReceiptMessageIdsByChat[chatId, default: []].insert(messageId)
        pendingReadReceiptMessageIdsByChat[chatId, default: []].insert(messageId)
        scheduleReadReceiptFlush()
    }

    private func scheduleReadReceiptFlush() {
        readReceiptFlushTask?.cancel()
        readReceiptFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.readReceiptFlushDelayNanos)
            } catch {
                return
            }
            await self.flushPendingReadReceipts()
        }
    }

    private func flushPendingReadReceipts() async {
        let batches = pendingReadReceiptMessageIdsByChat
        pendingReadReceiptMessageIdsByChat.removeAll()
        readReceiptFlushTask = nil

        for (chatId, messageIds) in batches {
            let sortedMessageIds = messageIds.sorted()
            do {
                try await service.markAsRead(chatId: chatId, messageIds: sortedMessageIds)
            } catch {
                for messageId in sortedMessageIds {
                    readReceiptMessageIdsByChat[chatId]?.remove(messageId)
                }
                Logger.app.warning(
                    "markAsRead batch failed for chat=\(chatId) count=\(sortedMessageIds.count): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Drafts

    func saveDraft(chatId: Int64, text: String?) {
        draftStore.setDraft(chatId: chatId, text: text)
        publish(store.updateRecord(chatId) { $0.draftMessage = text })
        saveChatsToCache()
        syncDraft(chatId: chatId, text: text)
    }

    /// Sends the draft to the server after the one before it for the same
    /// chat has finished or been cancelled, so an older draft cannot land
    /// after a newer one. No delay is added: the views already debounce, and
    /// leaving a chat or sending flushes at once.
    private func syncDraft(chatId: Int64, text: String?) {
        let previous = draftSyncTasks[chatId]?.task
        previous?.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            await self?.writeDraft(chatId: chatId, text: text)
            self?.draftSyncFinished(chatId: chatId, id: id)
        }
        draftSyncTasks[chatId] = DraftSync(id: id, task: task)
    }

    private func writeDraft(chatId: Int64, text: String?) async {
        guard !Task.isCancelled else { return }
        do {
            try await service.setDraft(chatId: chatId, text: text)
        } catch is CancellationError {
            return
        } catch {
            Logger.app.warning("setDraft failed for chat=\(chatId): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A write that is still the latest for its chat leaves the map; an older
    /// one finishing must not take the newer one's place with it.
    private func draftSyncFinished(chatId: Int64, id: UUID) {
        if draftSyncTasks[chatId]?.id == id {
            draftSyncTasks[chatId] = nil
        }
    }

    func getDraft(chatId: Int64) -> String? {
        draftStore.getDraft(chatId: chatId)
    }

    func syncWidget() {
        widgetSync.update(chats: filteredChats, isInBackground: isInBackground)
    }
}
