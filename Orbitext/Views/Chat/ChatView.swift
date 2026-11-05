import SwiftUI

struct ComposeTarget: Hashable {
    let chatId: Int64
    let replyToId: Int64?
    let replyToSenderName: String?
    let replyToPreview: String?
}

struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(AppRouter.self) private var router
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(MessageManager.self) private var messageManager
    @Environment(ChatMessageStore.self) private var chatMessageStore
    @Environment(BotKeyboardStore.self) private var botKeyboardStore

    let chatId: Int64
    var initialChat: ChatInfo?
    var scrollToMessageId: Int64?

    @State private var composeTarget: ComposeTarget? = nil
    @State private var forwardingMessage: MessageInfo? = nil
    @State private var scrollState = WatchChatScrollState()
    @State private var loadedChatId: Int64?
    @State private var leaveTask: Task<Void, Never>? = nil
    @State private var botUI = ChatBotUIState()
    /// Whether the chat is a group, copied from the directory by
    /// `ChatGroupFlagReader`. Reading the directory here would redraw the
    /// whole screen for a change to any chat; the flag changes once.
    @State private var isGroup = false

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                WatchChatTimeline(
                    isReady: scrollState.initialScrollDone,
                    atBottom: $scrollState.atBottom,
                    unreadNewCount: $scrollState.unreadNewCount,
                    onScrollViewAppear: {
                        guard !currentMessages.isEmpty else { return }
                        let isDeepLink = scrollToMessageId != nil
                        if !isDeepLink {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(WatchChatTimelineAnchor.bottom, anchor: .bottom)
                            }
                        }
                        // A chat opened at a message (search, reply, link) jumps
                        // to it after the reveal; load-older opens after that.
                        DispatchQueue.main.asyncAfter(deadline: .now() + WatchChatScrollState.paginationDelay(isDeepLink: isDeepLink)) {
                            scrollState.enablePagination()
                        }
                    },
                    onUserScrollingChanged: { scrollState.isUserScrolling = $0 },
                    onBottomDistanceChanged: {
                        scrollState.updateBottomDistance($0, viewportHeight: $1)
                    }
                ) { availableWidth in
                    ChatMessageListView(
                        chatId: chatId,
                        isGroup: isGroup,
                        availableWidth: availableWidth,
                        composeTarget: $composeTarget,
                        forwardingMessage: $forwardingMessage,
                        onLoadOlder: {
                            guard scrollState.paginationEnabled else { return }
                            scrollState.prepareOlderLoad(topOf: currentMessages)
                            await chatMessageStore.loadOlderMessages(chatId: chatId)
                        },
                        onInlineButton: { message, button in
                            await handleInlineButton(button, in: message)
                        }
                    )

                    ChatTypingFooter(chatId: chatId, fallback: initialChat)

                    PendingMessagesView(chatId: chatId)

                    ChatBottomInset(chatId: chatId, fallback: initialChat)
                }
                .background { WristScreenBackground() }
                .background { ChatGroupFlagReader(chatId: chatId, fallback: initialChat, isGroup: $isGroup) }
                .modifier(ChatNavigationChrome(chatId: chatId, fallback: initialChat))
                // Route compose through the root router so the path stays a
                // homogeneous [AppDestination]. Mixing types via
                // `.navigationDestination(item:)` on the same stack triggers
                // SwiftUI's AnyNavigationPath comparisonTypeMismatch fatal.
                .onChange(of: composeTarget) { _, new in
                    guard let new else { return }
                    router.push(.compose(new))
                    composeTarget = nil
                }
                .task(id: chatId) {
                    leaveTask?.cancel()
                    guard await chatSession.enter(chatId) else { return }
                    // Returning from the native watch editor must preserve
                    // this route's loaded history and scroll position, but a
                    // history the background freed while this screen was
                    // covered is loaded again, not shown blank.
                    guard chatSession.needsHistoryLoad(
                        chatId,
                        loadedChatId: loadedChatId,
                        initialScrollDone: scrollState.initialScrollDone
                    ) else { return }
                    loadedChatId = chatId
                    composeTarget = nil
                    forwardingMessage = nil
                    scrollState.resetForChatOpen()

                    guard let result = await chatSession.loadHistory(chatId, scrollToMessageId: scrollToMessageId) else { return }

                    // Set scroll target - onChange(of: scrollTarget) will:
                    // 1. Set initialScrollDone = true -> reveals messages
                    // 2. Scroll to the target only for deep-link opens
                    // Until then, the list shows skeletons (no jump visible)
                    scrollState.completeInitialLoad(target: result.scrollToViewID)
                }
                .onDisappear {
                    leaveTask?.cancel()
                    leaveTask = Task { @MainActor in
                        await Task.yield()

                        guard !Task.isCancelled else { return }
                        // Another screen pushed above the same chat is not a
                        // chat exit: the route decides. Closing the chat in
                        // TDLib and freeing its history is the session's, when
                        // the path stops holding the chat; this view only
                        // forgets what it loaded.
                        guard !chatSession.isPresented(chatId) else { return }
                        loadedChatId = nil
                        scrollState.resetForChatOpen()
                    }
                }
                .onChange(of: scrollState.scrollTarget) {
                    guard let target = scrollState.scrollTarget else { return }
                    let isDeepLink = scrollToMessageId != nil
                    if !scrollState.initialScrollDone {
                        // Reveal messages first. Regular chat opens scroll to
                        // the bottom from WatchChatTimeline.onAppear after the
                        // ScrollView exists; deep-link opens still need an
                        // explicit jump to the requested old message.
                        scrollState.revealInitialMessages()
                        if isDeepLink {
                            DispatchQueue.main.asyncAfter(deadline: .now() + WatchChatScrollState.deepLinkJumpDelay) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    } else {
                        // New message arrived (or just sent) and user is
                        // at the bottom - smoothly bring it into view.
                        // Without animation the change reads as a jerk;
                        // with animation it slides into place.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(WatchChatTimelineAnchor.bottom, anchor: .bottom)
                            }
                        }
                    }
                }
                // The history and the send queue are read by this modifier,
                // so a change to them does not redraw the whole screen.
                .modifier(ChatHistoryObserver(
                    chatId: chatId,
                    onFirstMessageChanged: {
                        // Restore the previous top row after prepending older
                        // messages so pagination does not visually jump.
                        guard let anchor = scrollState.consumeOlderLoadAnchor(in: currentMessages) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    },
                    onLastMessageIdChanged: { oldValue, newValue in
                        guard newValue != oldValue else { return }

                        // A removed last row needs bottom alignment too, including
                        // the empty state. Only a new message creates read/unread work.
                        switch scrollState.handleNewMessage(oldId: oldValue, message: currentMessages.last) {
                        case .ignore, .incrementUnread:
                            break
                        case .realignBottom(let lastMessageId):
                            // Let the shorter content lay out, then repair only
                            // this still-current, resting viewport. A new gesture,
                            // route exit or another history change cancels it.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                guard chatSession.isPresented(chatId),
                                      scrollState.canApplyBottomRealignment(
                                          lastMessageId: lastMessageId,
                                          currentLastMessageId: currentMessages.last?.id
                                      ) else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo(WatchChatTimelineAnchor.bottom, anchor: .bottom)
                                }
                            }
                        case .scrollAndMarkRead(let messageId):
                            Task {
                                await chatRepository.markAsRead(chatId: chatId, messageId: messageId)
                            }
                        }
                    },
                    // A bot rewriting the last message (menu navigation after a
                    // button press) can make it taller and push the bottom out of
                    // view, hiding the composer. Follow it back down if the reader
                    // was resting at the bottom.
                    onLastMessageChanged: { oldValue, newValue in
                        guard WatchChatScrollState.lastMessageLayoutChanged(from: oldValue, to: newValue),
                              let lastMessageId = newValue?.id,
                              scrollState.beginBottomPin() else { return }
                        // Let the new row lay out first, as for realignment.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            guard chatSession.isPresented(chatId),
                                  scrollState.canApplyBottomPin(
                                      lastMessageId: lastMessageId,
                                      currentLastMessageId: currentMessages.last?.id
                                  ) else {
                                scrollState.finishBottomPin()
                                return
                            }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo(WatchChatTimelineAnchor.bottom, anchor: .bottom)
                            }
                            // Hand back to the sentinel once the scroll has landed.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                scrollState.finishBottomPin()
                            }
                        }
                    },
                    onPendingCountChanged: { oldValue, newValue in
                        // A new pending message just appeared (user sent
                        // something - it sits in the local queue before TDLib
                        // confirms it). PendingMessagesView is INSIDE the
                        // ScrollView, so its row pushes the bottom sentinel
                        // out of view and we need to chase the bottom back.
                        guard scrollState.initialScrollDone, newValue > oldValue,
                              let lastMessage = currentMessages.last else { return }
                        scrollState.scrollTarget = lastMessage.viewID
                    }
                ))

                ChatComposerSection(
                    chatId: chatId,
                    fallback: initialChat,
                    isVisible: scrollState.canShowComposer,
                    onAttach: { router.push(.attachments(chatId: chatId)) },
                    onBotMenu: { botUI.sheet = .menu }
                )

                if scrollState.canShowUnreadButton {
                    ScrollToBottomButton(unreadNewCount: scrollState.unreadNewCount) {
                        scrollState.unreadNewCount = 0
                        scrollState.isFarFromBottom = false
                        // Execute every tap, including repeated returns with no new messages.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(WatchChatTimelineAnchor.bottom, anchor: .bottom)
                        }
                        HapticManager.tap()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: scrollState.canShowComposer)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: scrollState.canShowUnreadButton)
            .botInteractionPresentation(
                state: $botUI,
                keyboard: botKeyboardStore.replyKeyboard(for: chatId)?.keyboard,
                commands: botKeyboardStore.commands(for: chatId),
                onSheetDismissed: handleBotMenuDismissed,
                onSharePhone: {
                    Task { await messageManager.sharePhoneNumber(chatId: chatId) }
                }
            )
            // Separate from the history task above, whose early returns
            // skip work when returning from a pushed screen.
            .task(id: chatId) {
                // A deep link, a search hit or the support chat can open a
                // chat the list on screen does not hold.
                await chatRepository.loadChatIfNeeded(chatId)
            }
            .task(id: chatId) {
                guard !isChannel else { return }
                await botKeyboardStore.load(chatId: chatId)
            }
        }
        .sheet(item: $forwardingMessage) { message in
            ForwardChatPicker { targetChatId in
                Task {
                    await messageManager.forwardMessage(
                        fromChatId: chatId,
                        messageId: message.id,
                        toChatId: targetChatId
                    )
                }
                forwardingMessage = nil
            }
        }
    }

    /// For work done once the screen is up. A body that read this would
    /// redraw whenever any chat changes.
    private var isChannel: Bool {
        chatRepository.chat(id: chatId, fallback: initialChat).isChannel
    }

    /// For handlers that run after the screen is drawn; a body that read
    /// this would redraw whenever the history changes.
    private var currentMessages: [MessageInfo] {
        chatMessageStore.messages(for: chatId)
    }

    private var chatSession: ChatSessionModel {
        appState.chatSession
    }

    // MARK: - Bots

    private func handleInlineButton(_ button: InlineKeyboardButton, in message: MessageInfo) async {
        let result = await messageManager.pressInlineButton(button, in: message)
        // The answer can take seconds; if the user has left this chat (or
        // pushed another screen over it) by then, presenting or navigating
        // would act on the wrong screen.
        guard router.isTopChat(chatId) else { return }
        switch result {
        case .done:
            break
        case .notice(let text):
            botUI.notice = text
        case .alert(let text):
            botUI.alertText = text
        case .openLink(let url):
            botUI.sheet = .link(url)
        case .openChat(let chat):
            guard chat.id != chatId else { return }
            let isKnown = chatRepository.chat(id: chat.id) != nil
            router.showChat(chat.id, route: isKnown ? .chat(chat.id) : .resolvedChat(chat))
        case .openContact(let contact):
            router.push(.contactDetail(contact))
        }
    }

    private func handleBotMenuDismissed() {
        guard let selection = botUI.pendingSelection else { return }
        botUI.pendingSelection = nil
        switch selection {
        case .command(let command):
            Task { await messageManager.sendMessage(chatId: chatId, text: command.messageText) }
        case .keyboardButton(let button):
            handleReplyKeyboardButton(button)
        }
    }

    private func handleReplyKeyboardButton(_ button: ReplyKeyboardButton) {
        switch button.kind {
        case .text:
            let active = botKeyboardStore.replyKeyboard(for: chatId)
            Task {
                let outcome = await messageManager.sendMessage(chatId: chatId, text: button.text)
                guard outcome.wasAccepted, let active, active.keyboard?.isOneTime == true else { return }
                await botKeyboardStore.consumeReplyKeyboard(chatId: chatId, messageId: active.messageId)
            }
        case .requestLocation:
            router.push(.locationShare(chatId: chatId))
        case .requestPhoneNumber:
            botUI.confirmsPhoneShare = true
        case .unsupported:
            botUI.notice = L10n.string("Not available on Apple Watch")
        }
    }
}

struct ForwardChatPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatRepository.self) private var chatRepository
    let onSelect: (Int64) -> Void

    var body: some View {
        NavigationStack {
            List(chatRepository.chats) { chat in
                Button {
                    onSelect(chat.id)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        AvatarView(
                            title: chat.title,
                            id: chat.id,
                            photoFileId: chat.photoFileId,
                            isGroup: chat.isGroup,
                            isOnline: chat.isOnline
                        )
                        Text(chat.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .wristGlassRow()
            }
            .wristListStyle()
            .navigationTitle(L10n.string("Forward to"))
        }
    }
}
