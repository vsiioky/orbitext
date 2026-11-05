import SwiftUI

struct ChatMessageListView: View {
    @Environment(ChatMessageStore.self) private var chatMessageStore
    @Environment(MessageManager.self) private var messageManager
    @Environment(ChatRepository.self) private var chatRepository

    let chatId: Int64
    let isGroup: Bool
    let availableWidth: CGFloat
    @Binding var composeTarget: ComposeTarget?
    @Binding var forwardingMessage: MessageInfo?
    let onLoadOlder: () async -> Void
    var onInlineButton: ((MessageInfo, InlineKeyboardButton) async -> Void)?

    /// Pending close-then-open animation. Held so a rapid
    /// second tap on a different message cancels the in-flight delayed
    /// assignment instead of clobbering the new target.
    @State private var replyToggleTask: Task<Void, Never>?

    @State private var readVisibility = ScrollVisibilityReadCoordinator()

    /// The history is read here, not passed in by the screen: this view is
    /// redrawn for a change to it, and the screen is not.
    private var messages: [MessageInfo] {
        chatMessageStore.messages(for: chatId)
    }

    private var isLoadingMessages: Bool {
        chatMessageStore.isLoading(chatId: chatId)
    }

    private var isLoadingOlder: Bool {
        chatMessageStore.isLoadingOlder(chatId: chatId)
    }

    private var timeline: [ChatTimelineSection] {
        ChatTimelineSection.build(from: messages)
    }

    private func setReplyTarget(_ newTarget: ComposeTarget?) {
        replyToggleTask?.cancel()
        replyToggleTask = nil

        let current = composeTarget
        let isSwap = current?.replyToId != nil
            && newTarget?.replyToId != nil
            && current?.replyToId != newTarget?.replyToId

        if isSwap {
            withAnimation(.easeOut(duration: 0.2)) {
                composeTarget = nil
            }
            replyToggleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    composeTarget = newTarget
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                composeTarget = newTarget
            }
        }
    }

    var body: some View {
        loadingPlaceholders
        emptyState
        olderMessagesTrigger

        ForEach(timeline) { section in
            chatItemSection(section)
        }
    }

    @ViewBuilder
    private var loadingPlaceholders: some View {
        if isLoadingMessages {
            ForEach(0..<6, id: \.self) { _ in
                MessageSkeletonView()
                    .padding(AppConstants.UI.messageRowInsets)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if messages.isEmpty && !isLoadingMessages {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
                Text(L10n.string("No messages yet"))
                    .font(.caption)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private var olderMessagesTrigger: some View {
        if !messages.isEmpty {
            // The load-older sentinel is rendered unconditionally from
            // chat open. Reason: gating on a state flag delays the
            // sentinel's hierarchy insertion until the flag flips, at
            // which point
            // .onScrollVisibilityChange has no prior false->true
            // transition to detect - it just sees the sentinel
            // materialize in its position. The result was: scrolling
            // all the way to the top of an already-loaded list did not
            // fire load-older on the first attempt; the user had to
            // scroll back to the bottom and back up to trigger it.
            //
            // Now the sentinel lives from mount, its visibility tracks
            // naturally as the user scrolls. ChatView gates the call
            // until pagination is enabled, and ChatMessageStore ignores
            // exhausted-history repeats.
            if isLoadingOlder {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(AppConstants.UI.compactRowInsets)
            }
            // 30px frame: a 1px sentinel was too small for SwiftUI's
            // visibility tracking to register reliably on watchOS.
            // No exhausted-history guard in the closure: SwiftUI
            // re-creates the LoadOlderSentinelModifier on every body
            // re-eval but .onScrollVisibilityChange holds onto the FIRST
            // closure it was given. Captured view flags can therefore be
            // stale here. ChatView gates on paginationEnabled, while
            // ChatMessageStore owns the exhausted-history guard.
            ChatLoadOlderSentinel {
                Task { await onLoadOlder() }
            }
        }
    }

    @ViewBuilder
    private func chatItemSection(_ section: ChatTimelineSection) -> some View {
        if section.showsDateSeparator {
            DateSeparatorView(date: section.item.date)
                .padding(EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0))
        }

        switch section.item {
        case .album(let album):
            TimelineRowWindow(value: album) {
                albumRow(album)
            }
            .modifier(AlbumVisibilityReadModifier(
                album: album,
                chatId: chatId,
                repository: chatRepository,
                coordinator: $readVisibility
            ))
            .id(ChatItem.album(album).scrollID)
        case .message(let message):
            if message.content.isServiceMessage {
                ServicePillView(text: message.servicePillText ?? "")
                    .padding(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .id(message.viewID)
            } else {
                TimelineRowWindow(value: message) {
                    messageRow(for: message)
                }
                .modifier(MessageVisibilityReadModifier(
                    message: message,
                    chatId: chatId,
                    repository: chatRepository,
                    coordinator: $readVisibility
                ))
                .id(message.viewID)
            }
        }
    }

    private func albumRow(_ album: MessageAlbumInfo) -> some View {
            AlbumView(
                album: album,
                isGroup: isGroup,
                availableWidth: availableWidth,
                onReply: {
                    // Reply targets the first message of the album, matching
                    // how Telegram itself treats album replies.
                    setReplyTarget(ComposeTarget.reply(to: album, chatId: chatId))
                },
                onForward: { msg in forwardingMessage = msg }
            )
            .equatable()
            .padding(AppConstants.UI.messageRowInsets)
    }

    private func messageRow(for message: MessageInfo) -> some View {
        MessageRow(
            message: message,
            isGroup: isGroup,
            onReply: {
                setReplyTarget(ComposeTarget.reply(to: message, chatId: chatId))
            },
            onReact: { emoji in
                // Skip server reaction calls for messages that
                // are still in TDLib's outbound queue. The temp id we
                // hold here is unknown to Telegram and the call would
                // produce a phantom "Message not found" error. Wait for
                // updateMessageSendSucceeded to promote the message.
                guard !message.isSending else {
                    HapticManager.error()
                    return
                }
                Task {
                    let shouldRemove = chatMessageStore.optimisticToggleReaction(
                        chatId: chatId,
                        messageId: message.id,
                        reactionValue: emoji
                    )

                    let succeeded: Bool
                    if shouldRemove {
                        succeeded = await messageManager.removeReaction(chatId: chatId, messageId: message.id, emoji: emoji)
                    } else {
                        succeeded = await messageManager.setReaction(chatId: chatId, messageId: message.id, emoji: emoji)
                    }

                    if !succeeded {
                        _ = chatMessageStore.optimisticToggleReaction(
                            chatId: chatId,
                            messageId: message.id,
                            reactionValue: emoji
                        )
                    }
                }
            },
            onDelete: {
                Task {
                    if await messageManager.deleteMessage(chatId: chatId, messageId: message.id) {
                        chatMessageStore.removeMessage(chatId: chatId, messageId: message.id)
                    }
                }
            },
            onEdit: { newText in
                Task {
                    if let updated = await messageManager.editMessage(chatId: chatId, messageId: message.id, newText: newText) {
                        chatMessageStore.updateMessage(chatId: chatId, messageId: message.id) {
                            $0.content = updated.content
                        }
                    }
                }
            },
            onForward: { forwardingMessage = message },
            onInlineButton: { button in await onInlineButton?(message, button) }
        )
        .equatable()
        .padding(AppConstants.UI.messageRowInsets)
        // Reply lives in the long-press action sheet (presentActions in
        // MessageRow). The previous .swipeActions(edge: .leading) only
        // worked while the parent was a List - LazyVStack does not honor
        // it - so we rely on the long-press path on both code paths.
    }
}

extension ComposeTarget {
    static func reply(to message: MessageInfo, chatId: Int64) -> ComposeTarget {
        ComposeTarget(
            chatId: chatId,
            replyToId: message.id,
            replyToSenderName: message.senderName,
            replyToPreview: message.content.textPreview
        )
    }

    static func reply(to album: MessageAlbumInfo, chatId: Int64) -> ComposeTarget? {
        guard let first = album.firstMessage else { return nil }
        return ComposeTarget(
            chatId: chatId,
            replyToId: first.id,
            replyToSenderName: first.senderName,
            replyToPreview: album.caption?.maskingSpoilers.text ?? first.content.textPreview
        )
    }
}
