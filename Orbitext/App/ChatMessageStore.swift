import Foundation
import Observation

@MainActor
@Observable
final class ChatMessageStore {
    private let messageManager: MessageManager
    private let chatRepository: ChatRepository

    private var messagesByChatId: [Int64: [MessageInfo]] = [:]
    private var loadingChatIds: Set<Int64> = []
    private var loadingOlderChatIds: Set<Int64> = []
    private var exhaustedHistoryChatIds: Set<Int64> = []

    private enum MessageMutation {
        case incoming(MessageInfo)
        case sendCompleted(Int64, MessageInfo)
        case deleted(Set<Int64>)
        case updated(Int64, (inout MessageInfo) -> Void)
        case readThrough(Int64)
    }

    private struct MessageLoad {
        let id = UUID()
        var mutations: [MessageMutation] = []
    }

    private var initialLoads: [Int64: MessageLoad] = [:]
    private var olderLoads: [Int64: MessageLoad] = [:]

    private struct PropertyFetch {
        let id = UUID()
        let task: Task<MessageProperties?, Never>
    }

    /// Server-authoritative properties are scoped to the chat and message.
    /// Populated lazily on long-press menu open; invalidated when TDLib
    /// reports updateMessageEdited / updateMessageContent for that
    /// (chatId, messageId) pair so the next menu open refetches.
    private var messagePropertiesCache: [MessageKey: MessageProperties] = [:]
    private var inflightPropertyFetches: [MessageKey: PropertyFetch] = [:]

    /// The chat the user is currently viewing. Set by ChatView in
    /// .task and cleared in .onDisappear. clearInactiveChats() must
    /// not wipe the messages of this chat - otherwise a quick
    /// background/foreground cycle leaves the open chat empty
    /// (ChatView.task is keyed on chatId, so it does not refire on
    /// scenePhase .active, and the user sees a blank list).
    private(set) var activeChatId: Int64?

    func setActiveChat(_ chatId: Int64?) {
        activeChatId = chatId
    }

    init(messageManager: MessageManager, chatRepository: ChatRepository) {
        self.messageManager = messageManager
        self.chatRepository = chatRepository
    }

    func messages(for chatId: Int64) -> [MessageInfo] {
        messagesByChatId[chatId] ?? []
    }

    func isLoading(chatId: Int64) -> Bool {
        loadingChatIds.contains(chatId)
    }

    func isLoadingOlder(chatId: Int64) -> Bool {
        loadingOlderChatIds.contains(chatId)
    }

    func canLoadOlder(chatId: Int64) -> Bool {
        !exhaustedHistoryChatIds.contains(chatId)
    }

    /// A screen opens the chat: its history starts empty and live messages
    /// are kept in it from now on. Only an open chat, or one being loaded,
    /// holds an entry; events of every other chat leave this store alone.
    func reset(chatId: Int64) {
        forget(chatId: chatId)
        messagesByChatId[chatId] = []
    }

    /// The user left the chat: its history is freed, and live messages are
    /// not kept again until a screen opens the chat.
    func release(chatId: Int64) {
        forget(chatId: chatId)
        if messagesByChatId[chatId] != nil {
            messagesByChatId[chatId] = nil
        }
    }

    private func forget(chatId: Int64) {
        loadingChatIds.remove(chatId)
        loadingOlderChatIds.remove(chatId)
        exhaustedHistoryChatIds.remove(chatId)
        initialLoads.removeValue(forKey: chatId)
        olderLoads.removeValue(forKey: chatId)
        clearProperties(chatId: chatId)
    }

    /// Whether the chat has a history here, even an empty one. The
    /// background frees the history of every chat but the open one, so a
    /// screen that loaded once cannot take it for granted.
    func hasHistory(for chatId: Int64) -> Bool {
        messagesByChatId[chatId] != nil
    }

    /// Whether a screen has the chat open, or is loading its history. A
    /// message of any other chat has no history here to join.
    private func isOpen(chatId: Int64) -> Bool {
        messagesByChatId[chatId] != nil || loadingChatIds.contains(chatId)
    }

    /// Called after the account session has closed. Invalidates outstanding
    /// requests as well as cached rows so late responses cannot restore it.
    func resetAll() {
        for request in inflightPropertyFetches.values { request.task.cancel() }
        inflightPropertyFetches.removeAll()
        messagePropertiesCache.removeAll()
        initialLoads.removeAll()
        olderLoads.removeAll()
        messagesByChatId.removeAll()
        loadingChatIds.removeAll()
        loadingOlderChatIds.removeAll()
        exhaustedHistoryChatIds.removeAll()
        activeChatId = nil
    }

    @discardableResult
    func loadInitialMessages(chatId: Int64, scrollToMessageId: Int64? = nil) async -> MessageLoadingHelper.InitialLoadResult {
        guard !loadingChatIds.contains(chatId) else {
            return MessageLoadingHelper.InitialLoadResult(
                messages: messages(for: chatId),
                scrollToViewID: messages(for: chatId).last?.viewID
            )
        }

        let load = MessageLoad()
        initialLoads[chatId] = load
        loadingChatIds.insert(chatId)
        defer {
            if initialLoads[chatId]?.id == load.id {
                initialLoads.removeValue(forKey: chatId)
                loadingChatIds.remove(chatId)
            }
        }

        var result = await MessageLoadingHelper.loadInitial(
            chatId: chatId,
            scrollToMessageId: scrollToMessageId,
            messageManager: messageManager,
            chatRepository: chatRepository
        )

        guard !Task.isCancelled, let currentLoad = initialLoads[chatId], currentLoad.id == load.id else {
            return MessageLoadingHelper.InitialLoadResult(messages: [], scrollToViewID: nil)
        }

        var messages = result.messages
        replay(currentLoad.mutations, into: &messages, allowMissingSendCompletion: true)
        let lastReadOutboxId = chatRepository.chat(id: chatId)?.lastReadOutboxMessageId ?? 0
        if lastReadOutboxId > 0 {
            for i in messages.indices where messages[i].isOutgoing && messages[i].id <= lastReadOutboxId {
                messages[i].isRead = true
            }
        }
        messagesByChatId[chatId] = messages
        exhaustedHistoryChatIds.remove(chatId)
        result.messages = messages
        // Resolve against the merged history: a live deletion may remove
        // the target or leave only one surviving item of its media album.
        let target = scrollToMessageId.flatMap { id in messages.first { $0.id == id } } ?? messages.last
        if let target {
            let albumCount = messages.filter { $0.mediaAlbumId == target.mediaAlbumId }.count
            result.scrollToViewID = target.mediaAlbumId != 0 && albumCount > 1 ? "album:\(target.mediaAlbumId)" : target.viewID
        } else {
            result.scrollToViewID = nil
        }
        return result
    }

    func loadOlderMessages(chatId: Int64) async {
        guard !loadingChatIds.contains(chatId),
              !loadingOlderChatIds.contains(chatId),
              !exhaustedHistoryChatIds.contains(chatId),
              !Task.isCancelled,
              let anchorMessageId = messages(for: chatId).first?.id else { return }

        let load = MessageLoad()
        olderLoads[chatId] = load
        loadingOlderChatIds.insert(chatId)
        defer {
            if olderLoads[chatId]?.id == load.id {
                olderLoads.removeValue(forKey: chatId)
                loadingOlderChatIds.remove(chatId)
            }
        }

        // Yield to let SwiftUI render the loading spinner before starting the fetch
        await Task.yield()

        let result = await MessageLoadingHelper.loadOlder(
            chatId: chatId,
            anchorMessageId: anchorMessageId,
            existingIds: Set(messages(for: chatId).map(\.id)),
            messageManager: messageManager
        )

        guard !Task.isCancelled,
              let currentLoad = olderLoads[chatId], currentLoad.id == load.id,
              messages(for: chatId).first?.id == anchorMessageId else { return }

        if result.newMessages.isEmpty {
            exhaustedHistoryChatIds.insert(chatId)
            return
        }

        var newMessages = result.newMessages
        replay(currentLoad.mutations, into: &newMessages)
        let existingIds = Set(messages(for: chatId).map(\.id))
        newMessages.removeAll { existingIds.contains($0.id) }
        let lastReadOutboxId = chatRepository.chat(id: chatId)?.lastReadOutboxMessageId ?? 0
        if lastReadOutboxId > 0 {
            for i in newMessages.indices where newMessages[i].isOutgoing && newMessages[i].id <= lastReadOutboxId {
                newMessages[i].isRead = true
            }
        }
        messagesByChatId[chatId, default: []].insert(contentsOf: newMessages, at: 0)
        if !result.hasMore {
            exhaustedHistoryChatIds.insert(chatId)
        }
    }

    func handleIncomingMessage(_ message: MessageInfo) {
        guard isOpen(chatId: message.chatId) else { return }
        var messages = messages(for: message.chatId)
        guard !messages.contains(where: { $0.id == message.id }) else { return }

        var resolvedMessage = message
        if let replyId = resolvedMessage.replyToMessageId,
           let original = messages.first(where: { $0.id == replyId }) {
            resolvedMessage.replyToSenderName = original.senderName
            resolvedMessage.replyToPreview = FormattedString(text: original.content.textPreview)
        }

        messages.append(resolvedMessage)
        messagesByChatId[message.chatId] = messages
        record(.incoming(resolvedMessage), chatId: message.chatId)
    }

    func handleDeleteMessages(chatId: Int64, messageIds: [Int64]) {
        record(.deleted(Set(messageIds)), chatId: chatId)
        for messageId in messageIds { clearProperties(key: MessageKey(chatId: chatId, messageId: messageId)) }
        guard var messages = messagesByChatId[chatId] else { return }
        messages.removeAll { messageIds.contains($0.id) }
        messagesByChatId[chatId] = messages
    }

    func handleMessageSendCompleted(oldMessageId: Int64, message: MessageInfo) {
        var resolved = message
        let existing = messages(for: message.chatId)
        if let replyId = resolved.replyToMessageId {
            if let original = existing.first(where: { $0.id == replyId }) {
                resolved.replyToSenderName = original.senderName
                resolved.replyToPreview = FormattedString(text: original.content.textPreview)
            } else if let previous = existing.first(where: { $0.id == oldMessageId }),
                      previous.replyToMessageId == replyId {
                resolved.replyToSenderName = resolved.replyToSenderName ?? previous.replyToSenderName
                resolved.replyToPreview = resolved.replyToPreview ?? previous.replyToPreview
            }
        }
        let readThrough = chatRepository.chat(id: message.chatId)?.lastReadOutboxMessageId ?? 0
        if readThrough > 0, resolved.isOutgoing, resolved.id <= readThrough {
            resolved.isRead = true
        }
        let mutation = MessageMutation.sendCompleted(oldMessageId, resolved)
        record(mutation, chatId: message.chatId)
        clearProperties(key: MessageKey(chatId: message.chatId, messageId: oldMessageId))
        clearProperties(key: MessageKey(chatId: message.chatId, messageId: message.id))
        guard var messages = messagesByChatId[message.chatId] else { return }
        replay([mutation], into: &messages)
        messagesByChatId[message.chatId] = messages
    }

    func updateReadStatus(chatId: Int64, lastReadOutboxMessageId: Int64) {
        guard lastReadOutboxMessageId > 0 else { return }
        record(.readThrough(lastReadOutboxMessageId), chatId: chatId)
        guard var messages = messagesByChatId[chatId] else { return }
        var changed = false
        for i in messages.indices where messages[i].isOutgoing && !messages[i].isRead && messages[i].id <= lastReadOutboxMessageId {
            messages[i].isRead = true
            changed = true
        }
        if changed { messagesByChatId[chatId] = messages }
    }

    func handleReactionsUpdate(chatId: Int64, messageId: Int64, reactions: [ReactionInfo]) {
        updateMessage(chatId: chatId, messageId: messageId) { $0.reactions = reactions }
    }

    /// Acknowledge TDLib's updateMessageContentOpened. Today this is a no-op
    /// at the model layer because MessageInfo does not yet carry an
    /// "is-content-opened" flag for voice notes / view-once media; landing
    /// the routing now lets later work drive UI off the event without
    /// re-plumbing.
    func handleMessageContentOpened(chatId: Int64, messageId: Int64) {
        _ = (chatId, messageId)
    }

    // MARK: - MessageProperties cache

    /// Returns cached server-authoritative properties for this message,
    /// or nil if the cache has not been populated yet. UI code should
    /// fall back on the client-side `MessageInfo.isEditable` heuristic
    /// while nil, then refresh once `fetchMessageProperties` resolves.
    func cachedProperties(chatId: Int64, messageId: Int64) -> MessageProperties? {
        messagePropertiesCache[MessageKey(chatId: chatId, messageId: messageId)]
    }

    /// Fetch and cache MessageProperties for a single message. Returns
    /// the freshly fetched value, or the cached value if one is already
    /// in flight or stored. Safe to call from .onAppear / .task; the
    /// inflight guard collapses re-entrant calls into a single TDLib
    /// round-trip.
    @discardableResult
    func fetchMessageProperties(chatId: Int64, messageId: Int64) async -> MessageProperties {
        let key = MessageKey(chatId: chatId, messageId: messageId)
        if let cached = messagePropertiesCache[key] {
            return cached
        }
        let request: PropertyFetch
        if let existing = inflightPropertyFetches[key] {
            request = existing
        } else {
            let service = messageManager.service
            request = PropertyFetch(task: Task {
                try? await service.getMessageProperties(chatId: chatId, messageId: messageId)
            })
            inflightPropertyFetches[key] = request
        }

        let fetched = await request.task.value
        // An edit, deletion or chat reset can invalidate this exact request
        // while TDLib is answering. It must not publish stale capabilities
        // or remove a newer request for the same message.
        guard inflightPropertyFetches[key]?.id == request.id else {
            return messagePropertiesCache[key] ?? .default
        }
        inflightPropertyFetches.removeValue(forKey: key)
        guard let fetched, !request.task.isCancelled else { return .default }
        messagePropertiesCache[key] = fetched
        updateMessage(chatId: chatId, messageId: messageId) { $0.properties = fetched }
        return fetched
    }

    /// Drop cached properties for a message. Invoked when TDLib reports
    /// updateMessageEdited / updateMessageContent so the next menu open
    /// refetches the (now-changed) capability set.
    func invalidateMessageProperties(chatId: Int64, messageId: Int64) {
        clearProperties(key: MessageKey(chatId: chatId, messageId: messageId))
        updateMessage(chatId: chatId, messageId: messageId) { $0.properties = .default }
    }

    func updateMessage(chatId: Int64, messageId: Int64, _ transform: @escaping (inout MessageInfo) -> Void) {
        record(.updated(messageId, transform), chatId: chatId)
        guard var messages = messagesByChatId[chatId], messages.update(where: messageId, transform) else { return }
        messagesByChatId[chatId] = messages
    }

    func removeMessage(chatId: Int64, messageId: Int64) {
        handleDeleteMessages(chatId: chatId, messageIds: [messageId])
    }

    private func clearProperties(key: MessageKey) {
        // Every row of the open chat reads the cache: a write that removes
        // nothing would still redraw them all.
        if messagePropertiesCache[key] != nil {
            messagePropertiesCache.removeValue(forKey: key)
        }
        inflightPropertyFetches.removeValue(forKey: key)?.task.cancel()
    }

    private func clearProperties(chatId: Int64) {
        let keys = Set(messagePropertiesCache.keys).union(inflightPropertyFetches.keys)
        for key in keys where key.chatId == chatId { clearProperties(key: key) }
    }

    private func record(_ mutation: MessageMutation, chatId: Int64) {
        initialLoads[chatId]?.mutations.append(mutation)
        olderLoads[chatId]?.mutations.append(mutation)
    }

    /// Replay only changes received after the request started. Existing
    /// unchanged rows must not overwrite fresher history returned by TDLib.
    private func replay(_ mutations: [MessageMutation], into messages: inout [MessageInfo], allowMissingSendCompletion: Bool = false) {
        var deletedMessageIds: Set<Int64> = []
        for mutation in mutations {
            switch mutation {
            case .incoming(let message):
                deletedMessageIds.remove(message.id)
                if !messages.contains(where: { $0.id == message.id }) {
                    messages.append(message)
                }
            case .sendCompleted(let oldMessageId, let message):
                // Both IDs can be present when a history response already
                // contains the server row but a live temporary row was appended.
                if deletedMessageIds.contains(oldMessageId) || deletedMessageIds.contains(message.id) {
                    deletedMessageIds.formUnion([oldMessageId, message.id])
                    messages.removeAll { $0.id == oldMessageId || $0.id == message.id }
                    continue
                }
                // ChatView may have reset the pending row before this initial
                // request. A terminal event received during that load is still
                // authoritative even when its short snapshot has neither ID.
                guard allowMissingSendCompletion || messages.contains(where: { $0.id == oldMessageId || $0.id == message.id }) else { continue }
                messages.removeAll { $0.id == oldMessageId || $0.id == message.id }
                messages.append(message)
            case .deleted(let messageIds):
                deletedMessageIds.formUnion(messageIds)
                messages.removeAll { messageIds.contains($0.id) }
            case .updated(let messageId, let transform):
                messages.update(where: messageId, transform)
            case .readThrough(let messageId):
                for index in messages.indices where messages[index].isOutgoing && messages[index].id <= messageId {
                    messages[index].isRead = true
                }
            }
        }
        messages.sort {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }

    func optimisticToggleReaction(chatId: Int64, messageId: Int64, reactionValue: String) -> Bool {
        guard var messages = messagesByChatId[chatId],
              let messageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            return false
        }

        let normalizedReactionValue = reactionValue.normalizedReactionEmoji

        if let reactionIndex = messages[messageIndex].reactions.firstIndex(where: { $0.actionValue == normalizedReactionValue }) {
            if messages[messageIndex].reactions[reactionIndex].isSelected {
                messages[messageIndex].reactions[reactionIndex].isSelected = false
                messages[messageIndex].reactions[reactionIndex].count -= 1
                if messages[messageIndex].reactions[reactionIndex].count <= 0 {
                    messages[messageIndex].reactions.remove(at: reactionIndex)
                }
                messagesByChatId[chatId] = messages
                return true
            }

            messages[messageIndex].reactions[reactionIndex].isSelected = true
            messages[messageIndex].reactions[reactionIndex].count += 1
            messagesByChatId[chatId] = messages
            return false
        }

        messages[messageIndex].reactions.insert(
            ReactionInfo(
                emoji: reactionValue,
                actionValue: normalizedReactionValue,
                count: 1,
                isSelected: true
            ),
            at: 0
        )
        messagesByChatId[chatId] = messages
        return false
    }

    /// Clear messages for chats not currently being loaded.
    /// Called on memory warning / scenePhase .background to free RAM.
    /// Preserves the active chat so a background/foreground
    /// cycle does not blank the chat the user is currently viewing.
    func clearInactiveChats() {
        let active = activeChatId
        for chatId in messagesByChatId.keys
            where !loadingChatIds.contains(chatId) && chatId != active {
            messagesByChatId[chatId] = nil
        }
        // Preserve exhaustedHistoryChatIds for the active chat; otherwise
        // it would re-trigger pagination unnecessarily on return.
        if let active, exhaustedHistoryChatIds.contains(active) {
            exhaustedHistoryChatIds = [active]
        } else {
            exhaustedHistoryChatIds.removeAll()
        }
    }
}
