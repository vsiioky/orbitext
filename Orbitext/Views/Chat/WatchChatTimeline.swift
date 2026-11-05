import SwiftUI

struct WatchChatScrollState: Equatable {
    var scrollTarget: String?
    var atBottom = true
    var unreadNewCount = 0
    var anchorBeforeLoad: String?
    /// The top message before older history is prepended. It is turned into
    /// a row id only after the load: the last photo of an album cut by the
    /// page boundary is a single row before and part of the album row after.
    var olderLoadAnchorMessageId: Int64?
    var initialScrollDone = false
    var paginationEnabled = false
    var isUserScrolling = false {
        // A gesture takes over from a pending pin: the reader decides
        // where the viewport rests.
        didSet { if isUserScrolling { isPinningBottom = false } }
    }
    var isFarFromBottom = false
    /// Set while following an in-place edit of the last row back to the
    /// bottom (see beginBottomPin). Stands in for `atBottom`, which the
    /// taller row flips false before the follow-up scroll lands.
    private(set) var isPinningBottom = false

    var canShowUnreadButton: Bool {
        initialScrollDone && !atBottom && isFarFromBottom && !isUserScrolling && !isPinningBottom
    }

    var canShowComposer: Bool {
        initialScrollDone && (atBottom || isPinningBottom) && !isUserScrolling
    }

    mutating func resetForChatOpen() {
        scrollTarget = nil
        atBottom = true
        unreadNewCount = 0
        clearOlderLoadAnchor()
        initialScrollDone = false
        paginationEnabled = false
        isUserScrolling = false
        isFarFromBottom = false
        isPinningBottom = false
    }

    mutating func updateBottomDistance(_ distance: CGFloat, viewportHeight: CGFloat) {
        guard viewportHeight > 0 else { return }
        // Separate thresholds prevent flicker around the reveal boundary.
        if distance <= viewportHeight * 0.35 {
            isFarFromBottom = false
        } else if distance >= viewportHeight {
            isFarFromBottom = true
        }
    }

    mutating func completeInitialLoad(target: String?) {
        scrollTarget = target
        if target == nil { revealInitialMessages() }
    }

    mutating func revealInitialMessages() {
        initialScrollDone = true
    }

    mutating func prepareOlderLoad(anchorViewID: String?) {
        anchorBeforeLoad = anchorViewID
    }

    /// Delay before scrolling to the message a chat was opened at.
    static let deepLinkJumpDelay: TimeInterval = 0.3

    /// Load-older stays off until the opening scroll has landed, or its
    /// sentinel, briefly visible at the top, would pull in older history.
    static func paginationDelay(isDeepLink: Bool) -> TimeInterval {
        isDeepLink ? deepLinkJumpDelay + 0.5 : 0.5
    }

    mutating func prepareOlderLoad(topOf messages: [MessageInfo]) {
        anchorBeforeLoad = nil
        olderLoadAnchorMessageId = messages.first?.id
    }

    /// The id of the row that now holds the remembered top message, as the
    /// list renders `messages`: an album is one row named after the album.
    mutating func consumeOlderLoadAnchor(in messages: [MessageInfo]) -> String? {
        guard let messageId = olderLoadAnchorMessageId else { return consumeOlderLoadAnchor() }
        guard initialScrollDone else { return nil }
        olderLoadAnchorMessageId = nil
        return MessageAlbumInfo.group(messages).first { $0.contains(messageId: messageId) }?.scrollID
    }

    private mutating func clearOlderLoadAnchor() {
        anchorBeforeLoad = nil
        olderLoadAnchorMessageId = nil
    }

    mutating func consumeOlderLoadAnchor() -> String? {
        guard initialScrollDone, let anchor = anchorBeforeLoad else { return nil }
        anchorBeforeLoad = nil
        return anchor
    }

    mutating func enablePagination() {
        paginationEnabled = true
    }

    mutating func handleNewMessage(oldId: Int64?, message: MessageInfo?) -> WatchChatNewMessageAction {
        guard initialScrollDone else { return .ignore }

        // This is called when the last row changes, including deletion. A
        // shorter history can retain the old content offset on watchOS, so
        // realign the bottom without treating its surviving row as unread.
        guard let message else {
            return oldId == nil ? .ignore : realignBottomAfterRemoval(lastMessageId: nil)
        }
        if let oldId, message.id < oldId {
            return realignBottomAfterRemoval(lastMessageId: message.id)
        }
        guard oldId == nil || message.id > (oldId ?? 0) else { return .ignore }

        clearOlderLoadAnchor()

        if message.isOutgoing || atBottom {
            scrollTarget = message.viewID
            return .scrollAndMarkRead(messageId: message.id)
        }

        unreadNewCount += 1
        return .incrementUnread
    }

    private mutating func realignBottomAfterRemoval(lastMessageId: Int64?) -> WatchChatNewMessageAction {
        guard atBottom, !isUserScrolling else { return .ignore }
        clearOlderLoadAnchor()
        // Return a one-shot intent: the survivor may already equal
        // scrollTarget after the reader manually returned to the bottom.
        return .realignBottom(lastMessageId: lastMessageId)
    }

    func canApplyBottomRealignment(lastMessageId: Int64?, currentLastMessageId: Int64?) -> Bool {
        initialScrollDone && atBottom && !isUserScrolling && lastMessageId == currentLastMessageId
    }

    // MARK: - In-place edits of the last row

    /// True when the last row kept its id but may have changed height: a
    /// bot rewriting its menu text or keyboard after a button press, or a
    /// reaction bar appearing. Read receipts do not change the layout.
    static func lastMessageLayoutChanged(from old: MessageInfo?, to new: MessageInfo?) -> Bool {
        guard let old, let new, old.id == new.id else { return false }
        return old.content != new.content
            || old.replyMarkup != new.replyMarkup
            || old.reactions != new.reactions
    }

    /// A taller last row pushes the bottom sentinel out of view, which
    /// would hide the composer. A reader resting at the bottom stays
    /// pinned there; returns false when the reader is elsewhere.
    mutating func beginBottomPin() -> Bool {
        guard initialScrollDone, atBottom, !isUserScrolling else { return false }
        isPinningBottom = true
        return true
    }

    /// Unlike realignment this cannot require `atBottom`: the growth that
    /// started the pin has usually flipped it already.
    func canApplyBottomPin(lastMessageId: Int64, currentLastMessageId: Int64?) -> Bool {
        initialScrollDone && isPinningBottom && !isUserScrolling && lastMessageId == currentLastMessageId
    }

    mutating func finishBottomPin() {
        isPinningBottom = false
    }
}

enum WatchChatNewMessageAction: Equatable {
    case ignore
    case incrementUnread
    case scrollAndMarkRead(messageId: Int64)
    case realignBottom(lastMessageId: Int64?)
}

struct WatchChatTimeline<Content: View>: View {
    let isReady: Bool
    @Binding var atBottom: Bool
    @Binding var unreadNewCount: Int
    let onScrollViewAppear: () -> Void
    var onUserScrollingChanged: (Bool) -> Void = { _ in }
    var onBottomDistanceChanged: (CGFloat, CGFloat) -> Void = { _, _ in }
    @ViewBuilder var content: (_ availableWidth: CGFloat) -> Content

    var body: some View {
        if !isReady {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    MessageSkeletonView()
                        .padding(AppConstants.UI.messageRowInsets)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    // Eager VStack is intentional for watchOS chat history:
                    // initial loads are capped, and ScrollView needs final
                    // content height for deterministic bottom anchoring.
                    VStack(spacing: 0) {
                        content(geometry.size.width)

                        Color.clear
                            .frame(height: 1)
                            .id(WatchChatTimelineAnchor.bottom)
                            .modifier(BottomVisibilitySentinel(
                                atBottom: $atBottom,
                                unreadNewCount: $unreadNewCount
                            ))
                    }
                    // A wide item anywhere in the eager history must not
                    // become the width proposal for every other message.
                    .frame(width: geometry.size.width)
                }
                .onAppear(perform: onScrollViewAppear)
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    max(0, scroll.contentSize.height + scroll.contentInsets.bottom
                        - scroll.contentOffset.y - scroll.containerSize.height)
                } action: { _, distance in
                    onBottomDistanceChanged(distance, geometry.size.height)
                }
                .onScrollPhaseChange { _, phase in
                    onUserScrollingChanged(phase == .tracking || phase == .interacting || phase == .decelerating)
                }
            }
        }
    }
}

enum WatchChatTimelineAnchor {
    static let bottom = "__bottom_sentinel"
}

private struct BottomVisibilitySentinel: ViewModifier {
    @Binding var atBottom: Bool
    @Binding var unreadNewCount: Int

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollVisibilityChange(threshold: 0.5) { visible in
                atBottom = visible
                if visible { unreadNewCount = 0 }
            }
        } else {
            content.onAppear {
                atBottom = true
                unreadNewCount = 0
            }
        }
    }
}
