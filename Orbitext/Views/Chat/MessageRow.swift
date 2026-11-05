import SwiftUI

struct MessageRow: View {
    @Environment(MessageManager.self) private var messageManager
    @Environment(ChatMessageStore.self) private var chatMessageStore
    @AppStorage(QuickReactionPreference.storageKey) private var preferredQuickReaction = QuickReactionPreference.defaultEmoji
    let message: MessageInfo
    let isGroup: Bool
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onForward: (() -> Void)?
    var onInlineButton: ((InlineKeyboardButton) async -> Void)?

    @ScaledMetric(relativeTo: .caption2) private var timestampSize: CGFloat = 12
    @State private var showActions = false
    @State private var showEditSheet = false
    @State private var availableQuickReactions: [String] = []
    @State private var didLoadAvailableQuickReactions = false
    @State private var isSpoilerRevealed = false
    @State private var voicePlaybackRequest = 0

    /// Effective permissions for context-menu rendering: prefer cached
    /// server-authoritative properties, then any value already attached
    /// to MessageInfo, otherwise an optimistic default that lets the
    /// menu render the same affordances as before while the
    /// getMessageProperties round-trip is in flight.
    private var effectiveProperties: MessageProperties {
        if let cached = chatMessageStore.cachedProperties(chatId: message.chatId, messageId: message.id),
           cached.isResolved {
            return cached
        }
        if message.properties.isResolved {
            return message.properties
        }
        var fallback = MessageProperties.default
        fallback.canBeEdited = message.isEditable
        fallback.canBeReplied = !message.isSending && message.sendingFailure == nil
        fallback.canBeForwarded = !message.isSending && message.sendingFailure == nil
        fallback.canBeDeletedOnlyForSelf = !message.isSending
        fallback.canBeDeletedForAllUsers = message.isOutgoing && !message.isSending
        return fallback
    }

    private var quickReactionActions: [String] {
        guard !message.isSending, message.sendingFailure == nil else { return [] }
        let existing = message.reactions.compactMap(\.actionValue)
        let defaults = preferredQuickReactionDefaults(from: availableQuickReactions)
        var ordered: [String] = []
        for reaction in existing + defaults where !reaction.isEmpty {
            if !ordered.contains(reaction) {
                ordered.append(reaction)
            }
        }
        return Array(ordered.prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            if message.isOutgoing { Spacer(minLength: AppConstants.UI.Bubble.spacerMinLength) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: AppConstants.UI.BotKeyboard.spacing) {
                bubbleView

                // Sibling of the bubble, not inside it: the bubble's
                // gestures and combined accessibility element would
                // otherwise swallow the buttons.
                if let rows = message.replyMarkup?.inlineKeyboardRows {
                    InlineKeyboardView(rows: rows, isEnabled: !message.isSending) { button in
                        await onInlineButton?(button)
                    }
                    .padding(message.isOutgoing ? .trailing : .leading, MessageBubbleShape.tailExtent)
                }
            }

            if !message.isOutgoing { Spacer(minLength: AppConstants.UI.Bubble.spacerMinLength) }
        }
        .confirmationDialog(L10n.string("Message"), isPresented: $showActions) {
            let props = effectiveProperties
            if props.canBeReplied {
                Button(L10n.string("Reply")) { onReply?() }
            }
            if props.canBeEdited {
                Button(L10n.string("Edit")) { showEditSheet = true }
            }
            if props.canBeForwarded {
                Button(L10n.string("Forward")) { onForward?() }
            }
            ForEach(quickReactionActions, id: \.self) { emoji in
                Button(emoji) { onReact?(emoji) }
            }
            if props.canBeDeletedForAllUsers {
                Button(L10n.string("Delete"), role: .destructive) { onDelete?() }
            } else if props.canBeDeletedOnlyForSelf {
                Button(L10n.string("Delete"), role: .destructive) { onDelete?() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showEditSheet) {
            EditMessageSheet(text: message.currentText ?? "") { newText in
                onEdit?(newText)
            }
        }
    }

    // MARK: - Bubble

    @ViewBuilder
    private var bubbleView: some View {
        let bubble = bubbleContent
            .padding(.horizontal, AppConstants.UI.Bubble.horizontalPadding)
            .padding(.vertical, AppConstants.UI.Bubble.verticalPadding)
            // Reserve room on the sender side so MessageBubbleShape can
            // draw its tail without being clipped by .background bounds.
            .padding(message.isOutgoing ? .trailing : .leading, MessageBubbleShape.tailExtent)
            .background { WristBubbleBackground(isOutgoing: message.isOutgoing) }
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 2).onEnded {
                    Task { await handleDoubleTapReaction() }
                }
            )
            .onLongPressGesture {
                Task { await presentActions() }
            }
            .environment(\.spoilerReveal, $isSpoilerRevealed)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.isOutgoing ? L10n.string("You") : message.senderName): \(spokenContent)")
            .accessibilityActions {
                if message.content.hasSpoiler && !isSpoilerRevealed {
                    Button(L10n.string("Show spoiler")) { isSpoilerRevealed = true }
                }
            }
            .accessibilityValue(message.isOutgoing ? message.deliveryState.accessibilityLabel : "")

        if case .voice = message.content {
            bubble
                .onTapGesture { voicePlaybackRequest += 1 }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { voicePlaybackRequest += 1 }
        } else if message.content.contentHandlesTap {
            bubble
        } else {
            bubble.onTapGesture {
                Task { await presentActions() }
            }
        }
    }

    /// VoiceOver names a hidden spoiler instead of reading it; the reveal
    /// action or a tap on the cover switches to the full text.
    private var spokenContent: String {
        isSpoilerRevealed ? message.content.revealedTextPreview : message.content.textPreview.speakingSpoilerMasks
    }

    private var bubbleContent: some View {
        VStack(alignment: bubbleContentAlignment, spacing: 2) {
            if isGroup && !message.isOutgoing {
                Text(message.senderName)
                    .font(.system(size: AppConstants.UI.FontSize.small, weight: .semibold))
                    .foregroundStyle(WristTheme.Palette.warning)
            }

            if let origin = message.forwardedOrigin {
                ForwardInfoView(origin: origin)
            }

            if message.hasReplyPreview {
                ReplyPreviewView(
                    senderName: message.replyToSenderName,
                    preview: message.replyToPreview,
                    isOutgoing: message.isOutgoing
                )
            }

            MessageContentView(
                content: message.content,
                isOutgoing: message.isOutgoing,
                voicePlaybackRequest: voicePlaybackRequest
            )

            ReactionsBar(reactions: message.reactions) { emoji in
                onReact?(emoji)
            }

            HStack(spacing: 2) {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: timestampSize))
                    .foregroundStyle(message.isOutgoing ? .white : .secondary)
                if message.isOutgoing {
                    StateIconView(message: message)
                }
            }
        }
    }

    private var bubbleContentAlignment: HorizontalAlignment {
        // Animated emoji use the sticker renderer. Center compact media
        // above the wider timestamp instead of leaving a leading gap.
        if case .sticker = message.content,
           !message.hasReplyPreview, message.forwardedOrigin == nil,
           !isGroup || message.isOutgoing {
            return .center
        }
        return message.isOutgoing ? .trailing : .leading
    }

    // MARK: - Reactions

    @MainActor
    private func presentActions() async {
        // Fire the property fetch alongside the reactions lookup so the
        // dialog still opens immediately; the observable cache
        // re-renders the buttons once TDLib answers. Pulling cached
        // value first avoids redundant TDLib round-trips on repeat
        // long-presses for the same message.
        if chatMessageStore.cachedProperties(chatId: message.chatId, messageId: message.id) == nil {
            Task { @MainActor in
                await chatMessageStore.fetchMessageProperties(
                    chatId: message.chatId,
                    messageId: message.id
                )
            }
        }
        await loadAvailableQuickReactionsIfNeeded()
        showActions = true
    }

    @MainActor
    private func handleDoubleTapReaction() async {
        guard !message.isSending, message.sendingFailure == nil else { return }
        await loadAvailableQuickReactionsIfNeeded()
        let reaction = QuickReactionPreference.resolve(
            storedEmoji: preferredQuickReaction,
            available: availableQuickReactions
        )
        onReact?(reaction)
    }

    private func preferredQuickReactionDefaults(from available: [String]) -> [String] {
        var ordered: [String] = []
        let seeds = [
            preferredQuickReaction,
            QuickReactionPreference.defaultEmoji,
            "❤",
            "😂"
        ]

        for seed in seeds {
            let resolved = QuickReactionPreference.resolve(storedEmoji: seed, available: available)
            if !ordered.contains(where: { $0.normalizedReactionEmoji == resolved.normalizedReactionEmoji }) {
                ordered.append(resolved)
            }
        }

        return Array(ordered.prefix(3))
    }

    @MainActor
    private func loadAvailableQuickReactionsIfNeeded() async {
        guard !message.isSending, message.sendingFailure == nil else { return }
        if !didLoadAvailableQuickReactions {
            didLoadAvailableQuickReactions = true
            availableQuickReactions = await messageManager.loadAvailableReactions(
                chatId: message.chatId,
                messageId: message.id
            )
        }
    }
}

/// Lightweight translucent bubbles over the shared backdrop keep long histories
/// inexpensive to scroll. Material blur is reserved for the floating controls.
struct WristBubbleBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let isOutgoing: Bool
    var color: Color?

    private var fill: Color {
        if let color { return color }
        if isOutgoing { return WristTheme.Palette.outgoingBubble }
        return reduceTransparency ? Color(white: 0.18) : .white.opacity(0.11)
    }

    var body: some View {
        let shape = MessageBubbleShape(isOutgoing: isOutgoing, cornerRadius: 18)
        shape.fill(fill)
            .overlay {
                // The sheen goes on the rounded body only. A gradient clipped
                // to the tailed path is drawn into a bitmap of the whole
                // bubble, and the eager timeline keeps one per row: 2-3 MB
                // for a long message, enough to get a long chat killed for
                // memory. The tail sits in the gradient's clear end anyway.
                if !isOutgoing {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(
                            colors: [.white.opacity(0.07), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .padding(.leading, MessageBubbleShape.tailExtent)
                }
            }
            .overlay {
                shape.stroke(.white.opacity(contrast == .increased ? 0.4 : 0.14), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// Compared by data only: the closures are rebuilt on every parent render
/// but act on the same message, so `.equatable()` lets an unchanged row skip
/// its body when anything else in the chat updates.
extension MessageRow: Equatable {
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.isGroup == rhs.isGroup
    }
}
