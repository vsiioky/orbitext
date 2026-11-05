import Foundation
import Observation
import os

enum ChatListLoadingState: Equatable {
    case idle
    case initial
    case refresh
    case pagination

    var isLoadingChats: Bool {
        switch self {
        case .initial, .refresh:
            return true
        case .idle, .pagination:
            return false
        }
    }

    var isPaginating: Bool {
        self == .pagination
    }
}

/// One server write of a chat's draft. The id lets the write tell, when it
/// finishes, whether a newer one has taken its place in the map.
struct DraftSync {
    let id: UUID
    let task: Task<Void, Never>
}

struct PrefetchedChatPage {
    let folderId: Int64?
    let limit: Int
    let chats: [ChatInfo]
    /// Whether every chat TDLib returned became a row.
    let isComplete: Bool
    /// The store's revision when the request went out. The page cannot
    /// replace a chat that changed after it.
    let startedAtRevision: UInt64
}

/// What `ChatRepository.publish` does once the list on screen has changed.
struct ChatListPublishEffects: OptionSet {
    let rawValue: Int
    /// Write the list to its cold-start file.
    static let persist = ChatListPublishEffects(rawValue: 1 << 0)
    /// Hand the list to the widget.
    static let widget = ChatListPublishEffects(rawValue: 1 << 1)
}

@MainActor
@Observable
final class ChatRepository {
    /// The chat list on screen: the displayed list's rows in TDLib's order.
    /// Derived from `store` after every change that touches them.
    private(set) var visibleChats: [ChatInfo] = []
    /// Bumped by every change to the directory, listed or not, so that a view
    /// reading `chat(id:)` redraws when its chat changes.
    private(set) var directoryRevision: UInt64 = 0
    /// Every chat TDLib announced and each chat's place in each list. Only
    /// this class writes it, and always in place: copying it into a local
    /// before mutating would duplicate its dictionaries.
    @ObservationIgnored var store = ChatStore()
    @ObservationIgnored private(set) var displayedListID: ChatListID = .main
    @ObservationIgnored private var visibleIds: Set<Int64> = []

    /// The rows on screen. Assigning replaces the displayed list exactly and
    /// has no side effects; tests and previews do that, the app does not.
    var chats: [ChatInfo] {
        get { visibleChats }
        set { seedDisplayedList(with: newValue) }
    }

    var folders: [ChatFolder] = []
    var canLoadMoreChats = true
    var isInitialSyncComplete = false
    var chatListLoadingState: ChatListLoadingState = .idle

    var folderFilterEnabled = false {
        didSet {
            preferences.setFolderFilterEnabled(folderFilterEnabled)
            if folderFilterEnabled && !folders.isEmpty && folders.first(where: { $0.id == selectedFolderId }) == nil {
                selectedFolderId = folders.first?.id ?? 0
            }
            if oldValue != folderFilterEnabled {
                invalidateChatListPrefetch()
                prepareNextChatPageIfNeeded()
            }
        }
    }

    var selectedFolderId: Int64 = 0 {
        didSet {
            preferences.setSelectedFolderId(selectedFolderId)
            if oldValue != selectedFolderId {
                invalidateChatListPrefetch()
                prepareNextChatPageIfNeeded()
            }
        }
    }

    var activeFolderId: Int64? {
        guard folderFilterEnabled,
              selectedFolderId > 0,
              folders.contains(where: { $0.id == selectedFolderId }) else {
            return nil
        }
        return selectedFolderId
    }

    var chatListPrefetchFolderId: Int64? {
        guard folderFilterEnabled, selectedFolderId > 0 else {
            return nil
        }
        return selectedFolderId
    }

    var filteredChats: [ChatInfo] {
        chats
    }

    let service: TelegramServiceProtocol
    let draftStore: DraftStore
    let notificationManager: any NotificationManaging
    let widgetSync: any WidgetSyncing
    let preferences: any AppPreferencesStoring
    let chatListCache = ListCache<ChatInfo>(filename: "cached_chats.json")
    var folderChatListCaches: [Int64: ListCache<ChatInfo>] = [:]
    /// The folder whose list is on screen; nil for Main. Assigning moves the
    /// rows now on screen into that list, for tests that stage a scope.
    var loadedChatListFolderId: Int64? {
        get { displayedListID.folderId }
        set { moveDisplayedRows(to: ChatListID(folderId: newValue)) }
    }
    /// Folder whose chats the current TDLib client returned from getChats.
    /// Unlike `loadedChatListFolderId`, never set from the disk snapshot:
    /// only then does a missing folder position mean "not in the folder".
    var folderListConfirmedByClient: Int64?
    var notificationFolderWait: Duration = .seconds(AppConstants.Chat.notificationFolderWait)
    var chatListGeneration: UInt64 = 0
    /// Bumped only when the account's data is dropped (logout): unlike
    /// `chatListGeneration` it survives a client restart of the same account.
    private(set) var accountGeneration: UInt64 = 0
    var chatLoadLimit = AppConstants.Chat.loadLimit
    var prefetchedChatPage: PrefetchedChatPage?
    var chatListPrefetchTask: Task<PrefetchedChatPage?, Never>?
    var chatListPrefetchTargetFolderId: Int64?
    var chatListPrefetchTargetLimit: Int?
    var isPreparingNextChatPage = false
    var lastPaginationTime: Date = .distantPast
    var isInBackground = false
    var isLoadingChats: Bool {
        get { chatListLoadingState.isLoadingChats }
        set { chatListLoadingState = newValue ? .refresh : .idle }
    }
    var isLoadingMoreChats: Bool {
        get { chatListLoadingState.isPaginating }
        set { chatListLoadingState = newValue ? .pagination : .idle }
    }
    var isLoadingFolders = false
    var didAttemptFolderLoad = false
    var pendingMissingChats: [Int64: MessageInfo] = [:]
    var missingChatFetchTask: Task<Void, Never>?
    var readReceiptMessageIdsByChat: [Int64: Set<Int64>] = [:]
    var pendingReadReceiptMessageIdsByChat: [Int64: Set<Int64>] = [:]
    var readReceiptFlushTask: Task<Void, Never>?
    /// The latest server write of each chat's draft that has not finished;
    /// the next one waits for it. A finished write leaves the map.
    @ObservationIgnored var draftSyncTasks: [Int64: DraftSync] = [:]
    var readReceiptFlushDelayNanos: UInt64 = 2_500_000_000
    // Per-chat TTL for chat-action indicators (typing/recording/uploading).
    // Refreshed every time a chatAction event arrives; pruned by the expiry
    // task so a stale remote client cannot leave a ghost indicator on screen.
    var typingExpiryByChat: [Int64: ContinuousClock.Instant] = [:]
    var typingExpiryTask: Task<Void, Never>?
    /// TDLib repeats an action roughly every 5 s while it lasts.
    var typingExpiry: Duration = .seconds(6)
    var typingExpiryTick: Duration = .seconds(1)

    init(
        service: TelegramServiceProtocol,
        draftStore: DraftStore,
        notificationManager: any NotificationManaging,
        widgetSync: any WidgetSyncing,
        preferences: any AppPreferencesStoring
    ) {
        self.service = service
        self.draftStore = draftStore
        self.notificationManager = notificationManager
        self.widgetSync = widgetSync
        self.preferences = preferences
        self.folderFilterEnabled = preferences.folderFilterEnabled
        self.selectedFolderId = preferences.selectedFolderId

        // Restore cached chats for instant UI on launch
        if let cached = chatListCache.load(), !cached.isEmpty {
            _ = store.applySnapshot(cached.map(Self.restored), in: .main, mode: .restore)
            projectVisibleChats()
            self.isInitialSyncComplete = true
            self.chatLoadLimit = max(AppConstants.Chat.loadLimit, cached.count)
        }
    }

    /// One chat from the directory: any chat TDLib announced in this session,
    /// whether or not it is in the list on screen. Observable, so a view that
    /// reads it redraws when the chat changes.
    func chat(id chatId: Int64) -> ChatInfo? {
        _ = directoryRevision
        return store.chat(id: chatId, stampedFor: displayedListID)
    }

    /// The chat a screen draws: the directory's, else the one its route
    /// carried, else a blank one. Observable like `chat(id:)`.
    func chat(id chatId: Int64, fallback: ChatInfo?) -> ChatInfo {
        chat(id: chatId) ?? fallback ?? .placeholder(id: chatId)
    }

    var isInBackgroundState: Bool {
        get { isInBackground }
        set { isInBackground = newValue }
    }

    func reconcileFolderSelection() {
        guard !folders.isEmpty else {
            selectedFolderId = 0
            return
        }
        if selectedFolderId == 0 || !folders.contains(where: { $0.id == selectedFolderId }) {
            selectedFolderId = folders[0].id
        }
    }

    func resetLoadedState() {
        chatListGeneration &+= 1
        accountGeneration &+= 1
        store = ChatStore()
        displayedListID = .main
        visibleIds = []
        visibleChats = []
        directoryRevision &+= 1
        chatListCache.clear()
        folderChatListCaches.values.forEach { $0.clear() }
        folderChatListCaches.removeAll()
        // Folder snapshots from earlier launches, and corrupt backups, are not
        // tied to an account; the next session would merge them into its list.
        ListCache<ChatInfo>.removeFiles(withPrefix: "cached_chats")
        folderListConfirmedByClient = nil
        folders = []
        canLoadMoreChats = true
        isInitialSyncComplete = false
        chatLoadLimit = AppConstants.Chat.loadLimit
        prefetchedChatPage = nil
        chatListPrefetchTask?.cancel()
        chatListPrefetchTask = nil
        chatListPrefetchTargetFolderId = nil
        chatListPrefetchTargetLimit = nil
        isPreparingNextChatPage = false
        lastPaginationTime = .distantPast
        chatListLoadingState = .idle
        isLoadingFolders = false
        didAttemptFolderLoad = false
        pendingMissingChats.removeAll()
        readReceiptMessageIdsByChat.removeAll()
        pendingReadReceiptMessageIdsByChat.removeAll()
        readReceiptFlushTask?.cancel()
        readReceiptFlushTask = nil
        draftSyncTasks.values.forEach { $0.task.cancel() }
        draftSyncTasks.removeAll()
        missingChatFetchTask?.cancel()
        missingChatFetchTask = nil
        typingExpiryByChat.removeAll()
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
    }

    func beginChatListSession() {
        chatListGeneration &+= 1
        // A new client must confirm positive membership again. Keep known
        // removals until a fresh positive position arrives; stale cache pages
        // from the same account must not undo an already observed archive.
        store.beginSession()
        folderListConfirmedByClient = nil
        invalidateChatListPrefetch()
        chatListLoadingState = .idle
        pendingMissingChats.removeAll()
        missingChatFetchTask?.cancel()
        missingChatFetchTask = nil
    }

    // MARK: - Store and projection

    /// Applies a store change: bumps the directory, prunes cache files of
    /// lists that lost a chat, and, if the list on screen is touched, shows it
    /// again and runs `effects`. A change to a chat that is not on screen
    /// does nothing else.
    func publish(_ change: ChatStore.Change, effects: ChatListPublishEffects = []) {
        guard !change.isEmpty else { return }
        directoryRevision &+= 1
        removeTombstonedRowsFromOtherCaches(change.tombstoned)
        guard change.lists.contains(displayedListID) || !change.chatIds.isDisjoint(with: visibleIds) else { return }
        projectVisibleChats()
        if effects.contains(.persist) {
            saveChatsToCache()
        }
        if effects.contains(.widget) {
            syncWidget()
        }
    }

    /// Shows a list, or shows the one on screen again after a bulk change.
    func showList(_ list: ChatListID) {
        displayedListID = list
        directoryRevision &+= 1
        projectVisibleChats()
    }

    private func projectVisibleChats() {
        let projected = store.chats(in: displayedListID)
        visibleIds = Set(projected.map(\.id))
        visibleChats = projected
    }

    private func seedDisplayedList(with rows: [ChatInfo]) {
        _ = store.applySnapshot(rows, in: displayedListID, mode: .seed)
        directoryRevision &+= 1
        projectVisibleChats()
    }

    private func moveDisplayedRows(to list: ChatListID) {
        guard list != displayedListID else { return }
        let rows = visibleChats
        displayedListID = list
        seedDisplayedList(with: rows)
    }

    /// The cold-start file of a list that is not on screen keeps a row TDLib
    /// has since removed from it. Drain its pending write first, so that the
    /// write cannot bring the row back after this one.
    private func removeTombstonedRowsFromOtherCaches(_ tombstoned: [ChatListID: Set<Int64>]) {
        for (list, chatIds) in tombstoned where list != displayedListID {
            let cache: ListCache<ChatInfo>
            switch list {
            case .main: cache = chatListCache
            case .folder(let folderId): cache = self.cache(for: folderId)
            case .archive: continue
            }
            cache.flush()
            guard var cached = cache.load(), cached.contains(where: { chatIds.contains($0.id) }) else { continue }
            cached.removeAll { chatIds.contains($0.id) }
            cache.save(cached)
        }
    }

    /// A row from outside TDLib's updates (a page, a file, a fetched chat)
    /// keeps the draft the user typed on this watch.
    func withLocalDraft(_ chat: ChatInfo) -> ChatInfo {
        var chat = chat
        chat.draftMessage = draftStore.getDraft(chatId: chat.id)
        return chat
    }

    // MARK: - Cold-start files

    /// A row from a cold-start file, without its photo's file id. TDLib
    /// numbers files per instance, so the id saved by an earlier run can name
    /// another file in this one, or none yet; the photo returns when TDLib
    /// announces the chat.
    private static func restored(_ chat: ChatInfo) -> ChatInfo {
        var chat = chat
        chat.photoFileId = nil
        return chat
    }

    func saveChatsToCache() {
        let snapshot = store.chats(in: displayedListID).map { chat in
            var persisted = chat
            persisted.typingUserNames = []
            persisted.typingActionKind = .none
            persisted.isOnline = false
            return persisted
        }
        cache(for: displayedListID.folderId).save(snapshot)
    }

    @discardableResult
    func restoreCachedChats(for folderId: Int64?) -> Bool {
        guard let cached = cache(for: folderId).load() else {
            return false
        }
        let list = ChatListID(folderId: folderId)
        _ = store.applySnapshot(cached.map(Self.restored).map(withLocalDraft), in: list, mode: .restore)
        showList(list)
        isInitialSyncComplete = true
        chatLoadLimit = max(AppConstants.Chat.loadLimit, cached.count)
        Logger.app.debug(
            "Restored cached chat list: count=\(cached.count) folder=\(String(describing: folderId), privacy: .public)"
        )
        return true
    }

    /// Writes every pending cold-start file now, folders included: pruning a
    /// list that is not on screen saves its file through the same debounce.
    func flushChatListCaches() {
        chatListCache.flush()
        folderChatListCaches.values.forEach { $0.flush() }
    }

    func cache(for folderId: Int64?) -> ListCache<ChatInfo> {
        guard let folderId else {
            return chatListCache
        }
        if let cache = folderChatListCaches[folderId] {
            return cache
        }
        let cache = ListCache<ChatInfo>(filename: "cached_chats_folder_\(folderId).json")
        folderChatListCaches[folderId] = cache
        return cache
    }

    // MARK: - Error Handling Helper

    /// Performs an async mutation, playing an optional haptic on success. Throws on failure so callers can handle
    /// errors.
    func performMutation(haptic: (() -> Void)? = nil, _ action: () async throws -> Void) async throws {
        try await action()
        haptic?()
    }
}
