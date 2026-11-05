import Foundation
import Observation
import os
import WatchKit
import WidgetKit

@MainActor
@Observable
final class AppState: RemotePushHandling {
    let authManager: AuthManager
    let chatRepository: ChatRepository
    let messageManager: MessageManager
    let chatMessageStore: ChatMessageStore
    let botKeyboardStore: BotKeyboardStore
    let networkMonitor = NetworkMonitor()
    let voiceManager = VoiceManager()
    let errorPresenter = ErrorPresenter()
    let imageCache: ImageCache
    let router = AppRouter()
    let notificationManager: any NotificationManaging

    let service: TelegramServiceProtocol
    let lifecycle: AppLifecycleCoordinator
    let chatSession: ChatSessionModel
    let widgetSync: any WidgetSyncing
    let preferences: any AppPreferencesStoring
    var eventTask: Task<Void, Never>?
    var pendingSyncRequest = SyncRequest()
    var syncTask: Task<Void, Never>?
    var syncGeneration: UInt64 = 0
    /// Pending sends whose server result a background action is waiting for.
    var awaitedSendResults: Set<MessageKey> = []
    var lastBecameActiveTime: ContinuousClock.Instant = .now - .seconds(10)
    var cacheSizeMB = "…"
    /// While Clear cache runs, which takes as long as the files are many.
    var isClearingCache = false
    /// Counts the cache size refreshes: a scan that finishes after a newer
    /// one was started has a stale answer and is dropped.
    @ObservationIgnored var cacheRefreshGeneration: UInt64 = 0
    /// Measures the cache off the main actor, given the transport's cache
    /// directories and the recordings directory. A test replaces it.
    @ObservationIgnored var scanCacheSize: @Sendable ([URL], URL) -> Int64 = AppState.scanCacheSize
    @ObservationIgnored private var memoryPressureMonitor: MemoryPressureMonitor?

    init(
        service: any TelegramServiceProtocol,
        notificationManager: (any NotificationManaging)? = nil,
        widgetSync: (any WidgetSyncing)? = nil,
        preferences: (any AppPreferencesStoring)? = nil,
        memoryPressureSource: (any MemoryPressureSource)? = nil
    ) {
        let svc = service
        self.service = svc
        self.notificationManager = notificationManager ?? NotificationManager.shared
        self.widgetSync = widgetSync ?? WidgetSyncService()
        self.preferences = preferences ?? AppPreferencesStore()

        let draftStore = DraftStore()
        let messageQueue = MessageQueue()

        self.authManager = AuthManager(service: svc, errorPresenter: ErrorPresenter())
        self.lifecycle = AppLifecycleCoordinator(service: svc, authManager: self.authManager, networkMonitor: self.networkMonitor)
        self.chatRepository = ChatRepository(
            service: svc,
            draftStore: draftStore,
            notificationManager: self.notificationManager,
            widgetSync: self.widgetSync,
            preferences: self.preferences
        )
        self.messageManager = MessageManager(service: svc, messageQueue: messageQueue)
        self.chatMessageStore = ChatMessageStore(messageManager: self.messageManager, chatRepository: self.chatRepository)
        self.botKeyboardStore = BotKeyboardStore(service: svc)
        self.imageCache = ImageCache(service: svc)
        Task.detached(priority: .background) {
            await ImageCache.removeLegacyDiskCache()
        }
        let chatSession = ChatSessionModel(
            service: svc,
            notificationManager: self.notificationManager,
            messageStore: self.chatMessageStore,
            chatRepository: self.chatRepository,
            botKeyboardStore: self.botKeyboardStore,
            isPresented: { [authManager = self.authManager, router = self.router] chatId in
                authManager.authState == .ready && router.containsChat(chatId)
            }
        )
        self.chatSession = chatSession
        // The chat sessions follow the route. The model's presentation
        // closure holds the router, so the router holds the model weakly.
        router.onPathChanged = { [weak chatSession] in chatSession?.presentationDidChange() }

        // Share error presenter
        self.authManager.errorPresenter = self.errorPresenter
        self.messageManager.errorPresenter = self.errorPresenter

        lifecycle.host = self
        installNotificationActionHandlers()
        memoryPressureMonitor = MemoryPressureMonitor(source: memoryPressureSource ?? DispatchMemoryPressureSource()) { [weak self] in
            Task { @MainActor [weak self] in self?.handleMemoryPressure() }
        }
    }

    /// Test seam: whether a start began. Setting it stands in for a client
    /// somebody else started (or for a reset that allows a new start).
    var isInitialized: Bool {
        get { lifecycle.state.isStarted }
        set {
            if newValue {
                lifecycle.assumeStarted()
            } else {
                lifecycle.resetStart()
            }
        }
    }

    /// Test seam: the background callbacks that currently hold the transport.
    var backgroundOperations: Set<UUID> {
        Set(lifecycle.state.leases.keys)
    }

    func retry() async {
        guard lifecycle.beginTransition(.resetting) else { return }
        authManager.isLoading = true
        defer {
            lifecycle.endTransition(.resetting)
            authManager.isLoading = false
        }
        errorPresenter.dismiss()
        if await retryStartupWithoutResetIfNeeded() { return }
        guard await resetLocalAuthorizationIfNeeded() else { return }
        authManager.authState = .idle
        lifecycle.resetStart()
        await initialize()
    }

    func resetAuthMethodSelection() async {
        guard lifecycle.beginTransition(.resetting) else { return }
        errorPresenter.dismiss()
        authManager.isLoading = true
        defer {
            lifecycle.endTransition(.resetting)
            authManager.isLoading = false
        }
        if await retryStartupWithoutResetIfNeeded() { return }
        guard await resetLocalAuthorizationIfNeeded() else { return }
        authManager.clearQRCodeLinkAndThrottle()
        authManager.authState = .waitPhoneNumber
        lifecycle.resetStart()
        await initialize()
    }

    /// A bootstrap failure (for example, a locked Keychain) is not a logout.
    /// The transport retries it under its lifecycle lease without deleting the
    /// encrypted database or clearing the account's drafts, queue and caches.
    private func retryStartupWithoutResetIfNeeded() async -> Bool {
        do {
            return try await service.retryStartupIfNeeded()
        } catch is CancellationError {
            return true
        } catch {
            authManager.authState = .error(error.localizedDescription)
            errorPresenter.show(error)
            return true
        }
    }

    private func resetLocalAuthorizationIfNeeded() async -> Bool {
        guard !Task.isCancelled else { return false }
        resetSyncPipeline()
        messageManager.cancelQueueFlush()
        do {
            try await service.resetLocalSession()
            lifecycle.retireCurrentClient()
            clearLocalSessionData()
            return true
        } catch {
            errorPresenter.show(error)
            authManager.authState = .error(error.localizedDescription)
            return false
        }
    }

    /// Starts the client unless a start began already; returns once it is
    /// running. Scene activation and the notification actions call it.
    func initialize() async {
        await lifecycle.ensureStarted()
    }

    // MARK: - Event Loop

    private func startEventLoop() {
        // This service owns a single AsyncStream. Cancelling an awaiting
        // iterator terminates it, so auth reset/retry must retain this consumer.
        guard eventTask == nil else { return }
        let events = service.events
        eventTask = Task { [weak self, events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.handleEvent(event)
                }
            }
        }
    }

    func handleEvent(_ event: TDLibEvent) {
        // Events of a client the app ended (a logout or a reset) must not
        // reach the next account; generation markers are not applied either.
        guard lifecycle.admit(event) else { return }
        switch event {
        case .clientGenerationChanged:
            break
        case .chatListSessionStarted:
            chatRepository.beginChatListSession()
        case .authStateChanged(let state):
            Logger.app.info(
                "Auth state changed -> \(String(describing: state), privacy: .public); initialSync=\(self.chatRepository.isInitialSyncComplete) chats=\(self.chatRepository.chats.count)"
            )
            authManager.authState = state
            if state != .waitOtherDeviceConfirmation {
                authManager.setQRCodeLink(nil)
            }
            if state == .ready {
                tryStartPendingSyncIfPossible()
            } else {
                resetSyncPipeline()
                // The chat list is gone with the ready state, but the path
                // is not: the sessions of its chats end here.
                chatSession.presentationDidChange()
            }
        case .newMessage(let message):
            chatRepository.handleNewMessage(message)
            chatMessageStore.handleIncomingMessage(message)
        case .messageSendCompleted(let oldMessageId, let message):
            awaitedSendResults.remove(MessageKey(chatId: message.chatId, messageId: oldMessageId))
            chatRepository.handleMessageSendCompleted(oldMessageId: oldMessageId, message: message)
            chatMessageStore.handleMessageSendCompleted(oldMessageId: oldMessageId, message: message)
        case .remoteNotification(let info):
            // The decision awaits TDLib; a logout meanwhile must silence it.
            let generation = lifecycle.state.streamGeneration
            Task { await handleRemoteNotificationEvent(info, generation: generation) }
        case .chatUpdated(let chat):
            chatRepository.handleChatUpdate(chat)
            chatMessageStore.updateReadStatus(chatId: chat.id, lastReadOutboxMessageId: chat.lastReadOutboxMessageId)
        case .chatPositionChanged(let update):
            chatRepository.handleChatPositionUpdate(update)
            chatMessageStore.updateReadStatus(chatId: update.chat.id, lastReadOutboxMessageId: update.chat.lastReadOutboxMessageId)
        case .chatMentionCountChanged(let chatId, let count):
            chatRepository.setMentionCount(chatId: chatId, count: count)
        case .chatReactionCountChanged(let chatId, let count):
            chatRepository.setReactionCount(chatId: chatId, count: count)
        case .chatAction(let chatId, let names, let kind):
            chatRepository.handleChatAction(chatId: chatId, names: names, kind: kind)
        case .reactionsUpdated(let chatId, let messageId, let reactions):
            chatMessageStore.handleReactionsUpdate(chatId: chatId, messageId: messageId, reactions: reactions)
        case .deleteMessages(let chatId, let messageIds):
            chatRepository.handleDeleteMessages(chatId: chatId, messageIds: messageIds)
            chatMessageStore.handleDeleteMessages(chatId: chatId, messageIds: messageIds)
        case .connectionStateChanged(let state):
            networkMonitor.updateTDLibState(state)
            if !pendingSyncRequest.isEmpty {
                let pendingSummary = pendingSyncRequest.debugSummary
                Logger.app.debug(
                    "Connection update while sync pending: tdlib=\(state.rawValue, privacy: .public) pending=\(pendingSummary, privacy: .public)"
                )
            }
            tryStartPendingSyncIfPossible()
        case .foldersUpdated(let folders):
            chatRepository.folders = folders
            chatRepository.didAttemptFolderLoad = true
            chatRepository.reconcileFolderSelection()
            Logger.app.debug("Folders updated via TDLib: \(folders.count) folders")
            if chatRepository.folderFilterEnabled {
                widgetSync.update(chats: chatRepository.filteredChats, isInBackground: chatRepository.isInBackground)
                chatRepository.prepareNextChatPageIfNeeded()
            }
        case .qrCodeLink(let link):
            guard authManager.authState == .waitOtherDeviceConfirmation else { return }
            authManager.setQRCodeLink(link)
        case .messageContentOpened(let chatId, let messageId):
            chatMessageStore.handleMessageContentOpened(chatId: chatId, messageId: messageId)
        case .messagePropertiesInvalidated(let chatId, let messageId):
            chatMessageStore.invalidateMessageProperties(chatId: chatId, messageId: messageId)
        case .messageReplyMarkupChanged(let chatId, let messageId, let replyMarkup):
            chatMessageStore.updateMessage(chatId: chatId, messageId: messageId) { $0.replyMarkup = replyMarkup }
        case .messageContentChanged(let chatId, let messageId, let content):
            chatMessageStore.updateMessage(chatId: chatId, messageId: messageId) { $0.content = content }
        case .chatReplyMarkupChanged(let chatId, let message):
            botKeyboardStore.handleReplyMarkupChanged(chatId: chatId, message: message)
        }
    }
}

extension AppState: AppLifecycleHost {
    func prepareForClientStart() async {
        finishInterruptedLogoutIfNeeded()

        networkMonitor.onReconnected = { [weak self] in
            Task { @MainActor in await self?.messageManager.flushMessageQueue() }
        }

        notificationManager.registerCategories()
        await notificationManager.checkStatus()
        RemotePushCoordinator.shared.registerForRemoteNotifications()

        startEventLoop()
    }

    var isTransportPinned: Bool {
        voiceManager.isPlaying
    }

    func transportBackgroundStateDidChange(_ isInBackground: Bool) {
        chatRepository.isInBackgroundState = isInBackground
    }
}
