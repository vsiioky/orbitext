import Foundation

/// What a chat screen's session means outside the screen: telling TDLib the
/// chat is open, which chat the notification layer and the message store
/// treat as on screen, and when the session ends. ChatView keeps the timing
/// (it restarts and cancels its own tasks) and the scroll state, and asks
/// this class what to do.
///
/// Apart from the message store resetting itself, this is the only code that
/// writes the two active-chat marks, so there is one place to read when a
/// notification is suppressed for a chat.
///
/// The session of a chat lasts as long as its route is in the navigation
/// path, not as long as its screen is visible: a screen pushed over the chat
/// hides the chat view and brings it back, and a path replacement can drop a
/// covered chat without its view ever reporting it. So the chat is opened
/// once when a screen first enters it, and closed when the path no longer
/// holds it, whichever screen was on top, or when the account leaves the
/// ready state (the path outlives the chat list).
@MainActor
final class ChatSessionModel {
    private let service: TelegramServiceProtocol
    private let notificationManager: any NotificationManaging
    private let messageStore: ChatMessageStore
    private let chatRepository: ChatRepository
    private let botKeyboardStore: BotKeyboardStore
    private let presentation: @MainActor (Int64) -> Bool

    /// The chats TDLib was told are open and has not been told to close,
    /// each with the generation of the client that was told. TDLib counts
    /// the opens of a chat and keeps its messages loaded, and polls their
    /// views and reactions, until the count is back at zero, so an open sent
    /// again on every return to the chat would never be undone by the one
    /// close of the final exit. The count lives in the client: one that was
    /// replaced behind a standing route (TDLib closed and was restarted, the
    /// server ended the session) starts every chat at zero, so an open of an
    /// earlier generation is not an open any more. The next return to the
    /// chat opens it again, and its exit has nothing to close.
    private var openInTDLib: [Int64: TDClientGeneration] = [:]

    /// The latest open or close of each chat that has not finished. Whatever
    /// is sent for the chat next waits for it: the throttle may let a later
    /// request overtake an earlier one, and a close that did would leave the
    /// open standing.
    private var unfinishedCalls: [Int64: Task<Void, Never>] = [:]

    private enum TDLibCall {
        case open
        case close
    }

    /// `isPresented` answers whether a chat is still the user's place: signed
    /// in, with its route in the navigation stack.
    init(
        service: TelegramServiceProtocol,
        notificationManager: any NotificationManaging,
        messageStore: ChatMessageStore,
        chatRepository: ChatRepository,
        botKeyboardStore: BotKeyboardStore,
        isPresented: @escaping @MainActor (Int64) -> Bool
    ) {
        self.service = service
        self.notificationManager = notificationManager
        self.messageStore = messageStore
        self.chatRepository = chatRepository
        self.botKeyboardStore = botKeyboardStore
        presentation = isPresented
    }

    /// System editors and pushed screens cover a chat without ending it, so
    /// the view disappearing is not the chat being left: the route decides.
    func isPresented(_ chatId: Int64) -> Bool {
        presentation(chatId)
    }

    /// A screen entered the chat: a hint to TDLib to keep its history hot and
    /// prioritize its updates and downloads (sent once per stay, however
    /// often the screen comes back), then the marks. Returns false, marking
    /// nothing, when the screen was cancelled or left meanwhile.
    func enter(_ chatId: Int64) async -> Bool {
        let generation = service.clientGeneration
        if openInTDLib[chatId] != generation {
            openInTDLib[chatId] = generation
            await tell(.open, chatId, of: generation)
        }
        guard !Task.isCancelled, isPresented(chatId) else {
            // The route went while TDLib was being told; no path change is
            // left to close what this open started.
            if !isPresented(chatId) {
                await closeChatsLeftByRoute()
            }
            return false
        }
        notificationManager.activeChatId = chatId
        // The store keeps the open chat's messages when the app goes to the
        // background, so a quick background and foreground cycle does not
        // leave the open chat empty.
        messageStore.setActiveChat(chatId)
        notificationManager.clearNotifications(for: chatId)
        return true
    }

    /// Frees what the chat held and loads its history afresh. Nil when the
    /// caller was cancelled: a restarted screen must not act on the result.
    func loadHistory(_ chatId: Int64, scrollToMessageId: Int64?) async -> MessageLoadingHelper.InitialLoadResult? {
        messageStore.reset(chatId: chatId)
        let result = await messageStore.loadInitialMessages(chatId: chatId, scrollToMessageId: scrollToMessageId)
        return Task.isCancelled ? nil : result
    }

    /// Whether the screen that just entered the chat must load its history.
    /// It must when it never did or did not finish, and when the store freed
    /// the history while the screen was covered (the background frees every
    /// chat but the open one). A screen back from the native editor keeps
    /// the history and the scroll position it has.
    func needsHistoryLoad(_ chatId: Int64, loadedChatId: Int64?, initialScrollDone: Bool) -> Bool {
        loadedChatId != chatId || !initialScrollDone || !messageStore.hasHistory(for: chatId)
    }

    /// Where the user is changed: the navigation path, or the account's
    /// sign-in state. Closes what was left once a run of synchronous changes
    /// (popToRoot, then a push) has settled, so a chat that is back by then
    /// is not left.
    ///
    /// The sign-in state is a trigger of its own. When the account leaves
    /// the ready state the root view swaps the whole chat list for the
    /// sign-in screen and the path stays as it was (the router outlives the
    /// views), so a session the server ended, or a client TDLib closed and
    /// the app restarted, changes no path and would leave every chat marked
    /// open, its history in memory and its notifications muted, and would
    /// keep a chat from being opened for the session that follows.
    func presentationDidChange() {
        Task { [weak self] in
            await Task.yield()
            await self?.closeChatsLeftByRoute()
        }
    }

    /// Ends the session of every chat whose route is gone: forgets it,
    /// frees its history and the per-chat bookkeeping that would otherwise
    /// live until sign-out (reported read receipts, the bot's command menu),
    /// and tells TDLib to close it. A chat covered by another screen keeps
    /// its session. The marks are cleared only if they still point at the
    /// chat, as a sibling chat may have taken over through its own task.
    func closeChatsLeftByRoute() async {
        var left: [(chatId: Int64, openedBy: TDClientGeneration)] = []
        for chatId in openInTDLib.keys.sorted() where !isPresented(chatId) {
            if let generation = openInTDLib[chatId] {
                left.append((chatId, generation))
            }
        }
        guard !left.isEmpty else { return }
        for (chatId, _) in left {
            openInTDLib[chatId] = nil
        }
        for (chatId, _) in left {
            if notificationManager.activeChatId == chatId {
                notificationManager.activeChatId = nil
            }
            if messageStore.activeChatId == chatId {
                messageStore.setActiveChat(nil)
            }
            messageStore.release(chatId: chatId)
            chatRepository.releaseReadReceipts(chatId: chatId)
            botKeyboardStore.release(chatId: chatId)
        }
        // Every close is queued before the first one is waited for: a chat
        // of this batch that is entered again while an earlier close is in
        // flight must find its own close in the chain, or its open would be
        // sent first and shut by the close that follows it.
        var closes: [(chatId: Int64, call: Task<Void, Never>)] = []
        for (chatId, openedBy) in left {
            closes.append((chatId, queue(.close, chatId, of: openedBy)))
        }
        for close in closes {
            await finish(close.call, of: close.chatId)
        }
    }

    /// The account's session ended: no chat is open for anyone. The client
    /// is gone, so there is no close to send, and the next account's client
    /// has to be told again.
    func endAll() {
        openInTDLib.removeAll()
        notificationManager.activeChatId = nil
        messageStore.setActiveChat(nil)
    }

    /// Sends the call in a task of its own: the caller is usually a screen
    /// task that the view cancels when it disappears, and a cancelled request
    /// is never sent. Returns when the call has finished, however the caller
    /// fares meanwhile.
    private func tell(_ call: TDLibCall, _ chatId: Int64, of generation: TDClientGeneration) async {
        await finish(queue(call, chatId, of: generation), of: chatId)
    }

    /// Queues the call behind the chat's unfinished one, synchronously: the
    /// next request for the chat finds this one in the chain from here on,
    /// whatever the caller awaits first. The call is for the client of
    /// `generation`; once that client is gone the call is dropped, as the
    /// client now current is the next session's and knows nothing of it.
    private func queue(_ call: TDLibCall, _ chatId: Int64, of generation: TDClientGeneration) -> Task<Void, Never> {
        let previous = unfinishedCalls[chatId]
        let task = Task { [weak self] in
            await previous?.value
            await self?.send(call, chatId, of: generation)
        }
        unfinishedCalls[chatId] = task
        return task
    }

    private func finish(_ task: Task<Void, Never>, of chatId: Int64) async {
        await task.value
        if unfinishedCalls[chatId] == task {
            unfinishedCalls[chatId] = nil
        }
    }

    private func send(_ call: TDLibCall, _ chatId: Int64, of generation: TDClientGeneration) async {
        guard service.clientGeneration == generation else { return }
        switch call {
        case .open: await service.openChat(chatId)
        case .close: await service.closeChat(chatId)
        }
    }
}
