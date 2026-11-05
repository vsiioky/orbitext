import Foundation
import os

extension ChatRepository {
    /// Makes sure the directory knows a chat that was opened without being
    /// announced in this session (a deep link, a notification, a search hit).
    /// The chat is only looked up: it is not put into any list.
    func loadChatIfNeeded(_ chatId: Int64) async {
        guard store.chat(id: chatId, stampedFor: displayedListID) == nil else { return }
        let generation = chatListGeneration
        let since = store.revision
        do {
            let chat = try await service.getChat(chatId: chatId)
            // A sign-out while the request ran made the answer someone else's.
            guard !Task.isCancelled, generation == chatListGeneration else { return }
            publish(store.applySnapshot([withLocalDraft(chat)], in: displayedListID, mode: .directory(since: since)))
        } catch {
            Logger.app.debug("loadChatIfNeeded failed for chat=\(chatId): \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleMessageSendCompleted(oldMessageId: Int64, message: MessageInfo) {
        guard let lastMessageId = chat(id: message.chatId)?.lastMessage?.id,
              lastMessageId == oldMessageId || lastMessageId == message.id else { return }
        publish(store.updateRecord(message.chatId) { $0.lastMessage = message }, effects: [.persist, .widget])
    }

    func handleNewMessage(_ message: MessageInfo) {
        notifyIfNeeded(message, knownChat: chat(id: message.chatId))
        let isListed = store.isListed(message.chatId, in: displayedListID)
        // The chat moves when TDLib's updateChatLastMessage brings its new
        // position, a moment after this update; the count and the preview
        // change now.
        publish(store.updateRecord(message.chatId) { chat in
            chat.lastMessage = message
            if !message.isOutgoing {
                chat.unreadCount += 1
            }
        }, effects: [.persist, .widget])
        if !isListed {
            fetchMissingChat(for: message)
        }
    }

    /// Fields of a chat as TDLib's mirror has them. Generic status, title and
    /// read snapshots do not change membership or order: order=0 here may
    /// simply mean native positions are not loaded yet.
    func handleChatUpdate(_ chat: ChatInfo) {
        publish(store.applyFields(chat), effects: [.persist, .widget])
    }

    func handleChatPositionUpdate(_ update: ChatPositionUpdate) {
        publish(store.applyPositions(update), effects: [.persist, .widget])
    }

    /// Updates per-chat typing/recording/uploading state and refreshes a 6s TTL.
    /// TDLib re-emits the same chat action roughly every 5s while it's active,
    /// so a 6s expiry leaves a small grace window without keeping ghost
    /// indicators visible if the remote client crashes mid-action.
    func handleChatAction(chatId: Int64, names: [String], kind: ChatActionKind) {
        publish(store.setTyping(chatId, names: names, kind: kind))
        if names.isEmpty {
            typingExpiryByChat.removeValue(forKey: chatId)
        } else {
            typingExpiryByChat[chatId] = ContinuousClock.now.advanced(by: typingExpiry)
            startTypingExpiryTaskIfNeeded()
        }
    }

    /// Backward-compatible wrapper. Tests and any legacy callers using the
    /// old signature land on .typing kind, matching the old behaviour.
    func handleTypingState(chatId: Int64, names: [String]) {
        handleChatAction(chatId: chatId, names: names, kind: names.isEmpty ? .none : .typing)
    }

    private func startTypingExpiryTaskIfNeeded() {
        guard typingExpiryTask == nil else { return }
        typingExpiryTask = Task { @MainActor [weak self] in
            while let self, !self.typingExpiryByChat.isEmpty {
                try? await Task.sleep(for: self.typingExpiryTick)
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let expired = self.typingExpiryByChat
                    .filter { $0.value <= now }
                    .map(\.key)
                for chatId in expired {
                    self.typingExpiryByChat.removeValue(forKey: chatId)
                }
                self.publish(self.store.clearTyping(Set(expired)))
            }
            self?.typingExpiryTask = nil
        }
    }

    func setMentionCount(chatId: Int64, count: Int) {
        publish(store.updateRecord(chatId) { $0.mentionCount = count })
        saveChatsToCache()
    }

    func setReactionCount(chatId: Int64, count: Int) {
        publish(store.updateRecord(chatId) { $0.reactionCount = count })
        saveChatsToCache()
    }

    func handleDeleteMessages(chatId: Int64, messageIds: [Int64]) {
        guard let lastMessageId = chat(id: chatId)?.lastMessage?.id, messageIds.contains(lastMessageId) else { return }
        publish(store.updateRecord(chatId) { $0.lastMessage = nil }, effects: .persist)
    }

    /// Decides on TDLib's current state rather than the chat list: the list
    /// holds only its loaded page, and a reconnect replays messages that were
    /// already read on another device before their read marks arrive.
    private func notifyIfNeeded(_ message: MessageInfo, knownChat: ChatInfo?) {
        guard isInitialSyncComplete, !message.isOutgoing, message.content.isNotifiable,
              knownChat?.isMuted != true,
              // Saved Messages keeps forwards as incoming; saving one is no news.
              !service.isSelfChat(chatId: message.chatId),
              !isOpenOnScreen(message.chatId) else { return }
        let account = accountGeneration
        Task { [weak self] in
            guard let self else { return }
            let state: ChatNotificationState
            do {
                state = try await service.notificationState(chatId: message.chatId)
            } catch {
                Logger.app.warning("Notification state unavailable for chat \(message.chatId): \(error.localizedDescription, privacy: .public)")
                // Without TDLib's view, decide on the known copy as before.
                if let knownChat, account == accountGeneration, !isOpenOnScreen(message.chatId) {
                    postNotification(for: message, chatTitle: knownChat.title)
                }
                return
            }
            guard !state.isMuted,
                  state.lastReadInboxMessageId < message.id,
                  await selectedFolderMembership(of: message.chatId, knownState: state) != false,
                  // A logout while TDLib answered: the message is the old account's.
                  account == accountGeneration,
                  !isOpenOnScreen(message.chatId) else { return }
            postNotification(for: message, chatTitle: knownChat?.title ?? state.title)
        }
    }

    /// The open chat shows new messages itself, but only while the app is in
    /// front: activeChatId stays set after the wrist is lowered.
    private func isOpenOnScreen(_ chatId: Int64) -> Bool {
        !isInBackground && notificationManager.activeChatId == chatId
    }

    /// The system plays the notification haptic with the sound, so there is
    /// no separate haptic here: it fired even when notifications were off.
    private func postNotification(for message: MessageInfo, chatTitle: String) {
        notificationManager.postMessageNotification(
            chatTitle: chatTitle,
            senderName: message.senderName,
            // The system reads notification text aloud as written.
            preview: message.content.textPreview.speakingSpoilerMasks,
            chatId: message.chatId,
            messageKey: message.viewID,
            playSound: true
        )
    }

    /// Whether the chat belongs to the selected folder: nil when no folder is
    /// selected or TDLib cannot tell, in which case nothing is suppressed.
    func selectedFolderMembership(of chatId: Int64, knownState: ChatNotificationState? = nil) async -> Bool? {
        guard let folderId = notificationFolderId else { return nil }
        if store.isListed(chatId, in: .folder(folderId)) {
            return true
        }
        do {
            let state: ChatNotificationState
            if let knownState {
                state = knownState
            } else {
                state = try await service.notificationState(chatId: chatId)
            }
            if state.folderIds.contains(folderId) {
                return true
            }
            // TDLib reports a folder position only inside the part of the folder
            // this client has loaded. A new message lifts the chat to the top of
            // every list it is in, so once getChats returned this folder, a
            // missing position means the chat is outside it.
            if folderListConfirmedByClient == folderId {
                return false
            }
            guard await waitForFolderConfirmation(folderId) else { return nil }
            return try await service.notificationState(chatId: chatId).folderIds.contains(folderId)
        } catch {
            Logger.app.warning("Folder membership unknown for chat \(chatId): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The folder that limits notifications. Before the folder list arrives
    /// the saved selection still applies; afterwards only if it still exists.
    private var notificationFolderId: Int64? {
        guard folderFilterEnabled, selectedFolderId > 0 else { return nil }
        guard didAttemptFolderLoad else { return selectedFolderId }
        return folders.contains(where: { $0.id == selectedFolderId }) ? selectedFolderId : nil
    }

    /// On a cold start, waits for this client's first page of the folder so a
    /// missing position can be trusted. False if it does not arrive in time.
    private func waitForFolderConfirmation(_ folderId: Int64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + notificationFolderWait
        while folderListConfirmedByClient != folderId {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(until: min(deadline, clock.now + .milliseconds(50)))
            } catch {
                return false
            }
        }
        return true
    }

    private func fetchMissingChat(for message: MessageInfo) {
        if folderFilterEnabled {
            return
        }
        pendingMissingChats[message.chatId] = message
        startMissingChatFetchWorkerIfNeeded()
    }

    private func startMissingChatFetchWorkerIfNeeded() {
        guard missingChatFetchTask == nil else { return }

        let service = service
        missingChatFetchTask = Task { [weak self] in
            guard let self else { return }

            while true {
                let next = await MainActor.run { () -> (Int64, MessageInfo, UInt64)? in
                    guard let first = self.pendingMissingChats.first else {
                        self.missingChatFetchTask = nil
                        return nil
                    }
                    self.pendingMissingChats.removeValue(forKey: first.key)
                    return (first.key, first.value, self.store.revision)
                }

                guard let (chatId, message, since) = next else { return }

                var fetchedChat: ChatInfo?
                do {
                    fetchedChat = try await service.getChat(chatId: chatId)
                } catch is CancellationError {
                    return
                } catch {
                    Logger.app.warning("fetchMissingChat failed for chat=\(chatId): \(error.localizedDescription, privacy: .public)")
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled, let fetchedChat else { return }
                    self.applyFetchedChat(fetchedChat, for: message, since: since)
                }
            }
        }
    }

    /// A chat fetched because a message arrived for one the list lacks. It
    /// enters Main only if Main reports a positive order and nothing newer
    /// from TDLib says otherwise: an archived chat stays out.
    private func applyFetchedChat(_ chat: ChatInfo, for message: MessageInfo, since: UInt64) {
        var change = store.applySnapshot([withLocalDraft(chat)], in: .main, mode: .fetched(since: since))
        change.formUnion(store.updateRecord(chat.id) { record in
            if (record.lastMessage?.id ?? 0) < message.id {
                record.lastMessage = message
            }
        })
        publish(change, effects: [.persist, .widget])
    }
}
