import Foundation
import os
import WatchKit

// MARK: - Push Notifications & Remote Data

extension AppState {
    enum NotificationSuppressionReason: Equatable {
        case activeChat
        case mutedChat
        case outsideSelectedFolder
    }

    struct NotificationPresentationDecision: Equatable {
        let shouldPost: Bool
        let suppressionReason: NotificationSuppressionReason?

        static let post = Self(shouldPost: true, suppressionReason: nil)

        static func suppress(_ reason: NotificationSuppressionReason) -> Self {
            Self(shouldPost: false, suppressionReason: reason)
        }
    }

    enum NotificationPresentationPolicy {
        /// `isInSelectedFolder` is nil when no folder is selected or membership
        /// is unknown; only a known "no" suppresses the notification.
        static func decision(
            info: RemoteNotificationInfo,
            matchingChat: ChatInfo?,
            activeChatId: Int64?,
            isInSelectedFolder: Bool?
        ) -> NotificationPresentationDecision {
            if activeChatId == info.chatId {
                return .suppress(.activeChat)
            }
            if matchingChat?.isMuted == true {
                return .suppress(.mutedChat)
            }
            if isInSelectedFolder == false {
                return .suppress(.outsideSelectedFolder)
            }
            return .post
        }
    }

    func registerPushDeviceToken(_ token: Data) async {
        await service.updatePushDeviceToken(token)
    }

    func handleRemotePush(userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        Logger.app.debug("Remote push received")

        let outcome = await lifecycle.withLease(.remotePush, policy: .remotePush) {
            await processRemotePush(userInfo)
        }
        switch outcome {
        case .ran(let result):
            return result
        case .skipped(let reason):
            Logger.app.debug("Remote push skipped: \(String(describing: reason), privacy: .public)")
            return .noData
        }
    }

    private func processRemotePush(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        do {
            // Text, not the system's dictionary, leaves the main actor.
            let payload = try RemotePushPayload(userInfo: userInfo)
            let hasNewData = try await service.handleRemotePush(payload: payload)
            if hasNewData {
                try? await Task.sleep(for: .seconds(AppConstants.App.remotePushSyncDelay))
            }
            // watchOS gives background push handlers a tight window (~30s).
            // If the system has cancelled us mid-sleep, do NOT continue
            // spending the budget on a sync the system already declared
            // done - return early with the most informative result we
            // already computed.
            if Task.isCancelled {
                return hasNewData ? .newData : .noData
            }

            if authManager.authState == .ready && hasNewData {
                let request = SyncRequestFactory.remotePush()
                Logger.app.info("Remote push sync requested: \(request.debugSummary, privacy: .public)")
                enqueueSync(request)
                if await waitForSyncPipelineToDrain(timeout: 8) == .drained {
                    widgetSync.update(chats: chatRepository.filteredChats, isInBackground: chatRepository.isInBackgroundState)
                }
            }

            return hasNewData ? .newData : .noData
        } catch is CancellationError {
            // System cancellation is not an application failure - surface
            // the lack of completed work, not .failed (which marks the
            // push as needing retry).
            return .noData
        } catch {
            Logger.app.error("Remote push handling failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func handleRemoteNotificationEvent(_ info: RemoteNotificationInfo, generation: TDClientGeneration? = nil) async {
        let isInSelectedFolder = await chatRepository.selectedFolderMembership(of: info.chatId)
        let matchingChat = chatRepository.chat(id: info.chatId)
        let decision = NotificationPresentationPolicy.decision(
            info: info,
            matchingChat: matchingChat,
            activeChatId: notificationManager.activeChatId,
            isInSelectedFolder: isInSelectedFolder
        )
        guard decision.shouldPost else {
            if let reason = decision.suppressionReason {
                Logger.app.debug("Remote notification suppressed: \(String(describing: reason), privacy: .public)")
            }
            return
        }

        if let generation, !lifecycle.state.isCurrent(generation) {
            Logger.app.debug("Remote notification dropped: its session ended")
            return
        }
        let chatTitle = matchingChat?.title ?? info.chatTitle
        notificationManager.postMessageNotification(
            chatTitle: chatTitle,
            senderName: info.senderName,
            preview: info.preview,
            chatId: info.chatId,
            messageKey: info.notificationKey,
            playSound: info.playSound
        )
    }

    // MARK: - Notification Actions

    /// Installed from `init`: watchOS can deliver an action right after a cold
    /// launch, before any view has run `initialize()`.
    func installNotificationActionHandlers() {
        notificationManager.onReply = { [weak self] chatId, text in
            await self?.handleNotificationReply(chatId: chatId, text: text)
        }
        notificationManager.onMarkRead = { [weak self] chatId in
            await self?.handleNotificationMarkRead(chatId: chatId)
        }
        notificationManager.onOpenChat = { [weak self] chatId in
            Task { @MainActor in
                self?.router.openChat(chatId)
            }
        }
    }

    func handleNotificationReply(
        chatId: Int64,
        text: String,
        readyTimeout: TimeInterval = AppConstants.App.notificationActionReadyTimeout,
        deliveryTimeout: TimeInterval = AppConstants.App.notificationActionDeliveryTimeout
    ) async {
        let policy = LeasePolicy.notificationAction(readyTimeout: readyTimeout)
        let outcome = await lifecycle.withLease(.notificationReply, policy: policy) {
            let send = await messageManager.sendTrackedMessage(chatId: chatId, text: text)
            switch send.outcome {
            case .cancelled:
                messageManager.messageQueue.enqueue(chatId: chatId, text: text)
            case .failed:
                // Nobody saw the error: keep the dictated text in the chat as
                // failed, with retry and remove, instead of dropping it.
                let id = messageManager.messageQueue.enqueue(chatId: chatId, text: text)
                messageManager.messageQueue.markFailed(id)
            case .sent, .queued:
                break
            }
            // A pending message is only in TDLib's local database. Stay awake
            // until the server answers, or the reply waits for the next launch.
            if let accepted = send.accepted {
                await waitForSendResult(of: MessageKey(chatId: chatId, messageId: accepted.id), timeout: deliveryTimeout)
            }
        }
        switch outcome {
        case .ran:
            break
        case .skipped(.signedOut):
            // Never queue for a later session: it may belong to another account.
            Logger.app.warning("Notification reply dropped: account is signed out")
        case .skipped:
            // Keep the dictated text: the queue is flushed after reconnect and sync.
            Logger.app.warning("Notification reply queued: client was not ready in time")
            messageManager.messageQueue.enqueue(chatId: chatId, text: text)
        }
    }

    private func waitForSendResult(of key: MessageKey, timeout: TimeInterval) async {
        awaitedSendResults.insert(key)
        defer { awaitedSendResults.remove(key) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(max(0, timeout))
        while awaitedSendResults.contains(key), clock.now < deadline {
            do {
                try await clock.sleep(until: min(deadline, clock.now + .milliseconds(50)))
            } catch {
                return
            }
        }
        if awaitedSendResults.contains(key) {
            Logger.app.warning("Notification reply still pending after \(timeout)s; TDLib will resend it")
        }
    }

    func handleNotificationMarkRead(
        chatId: Int64,
        readyTimeout: TimeInterval = AppConstants.App.notificationActionReadyTimeout
    ) async {
        let policy = LeasePolicy.notificationAction(readyTimeout: readyTimeout)
        _ = await lifecycle.withLease(.notificationMarkRead, policy: policy) {
            guard let messageId = await latestMessageId(inChat: chatId) else { return }
            await chatRepository.markAsRead(chatId: chatId, messageId: messageId)
        }
    }

    /// Prefers TDLib's chat over the list restored from disk at launch, which
    /// can predate the message that produced the notification.
    private func latestMessageId(inChat chatId: Int64) async -> Int64? {
        do {
            return try await service.getChat(chatId: chatId).lastMessage?.id
        } catch {
            Logger.app.warning("Notification mark-as-read: getChat failed: \(error.localizedDescription, privacy: .public)")
            return chatRepository.chat(id: chatId)?.lastMessage?.id
        }
    }
}
