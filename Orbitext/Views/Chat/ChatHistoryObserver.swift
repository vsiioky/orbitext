import SwiftUI

/// Tells the chat screen when the end of its history, or its queue of unsent
/// messages, changes. The history is read here and not by the screen, so the
/// screen is not redrawn for every change to a message: the handlers run for
/// the changes that move the scroll position.
struct ChatHistoryObserver: ViewModifier {
    @Environment(ChatMessageStore.self) private var chatMessageStore
    @Environment(MessageManager.self) private var messageManager
    let chatId: Int64
    /// The first row changed: older history was prepended or the chat reset.
    let onFirstMessageChanged: () -> Void
    let onLastMessageIdChanged: (_ old: Int64?, _ new: Int64?) -> Void
    /// The last message changed in place or was replaced.
    let onLastMessageChanged: (_ old: MessageInfo?, _ new: MessageInfo?) -> Void
    let onPendingCountChanged: (_ old: Int, _ new: Int) -> Void

    func body(content: Content) -> some View {
        let messages = chatMessageStore.messages(for: chatId)
        let pendingCount = messageManager.messageQueue.pendingFor(chatId: chatId).count
        content
            .onChange(of: messages.first?.id) { _, _ in onFirstMessageChanged() }
            .onChange(of: messages.last?.id) { old, new in onLastMessageIdChanged(old, new) }
            .onChange(of: messages.last) { old, new in onLastMessageChanged(old, new) }
            .onChange(of: pendingCount) { old, new in onPendingCountChanged(old, new) }
    }
}
