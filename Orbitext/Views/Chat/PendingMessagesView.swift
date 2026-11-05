import SwiftUI

struct PendingMessagesView: View {
    @Environment(MessageManager.self) private var messageManager
    let chatId: Int64

    /// Per-pending-message action sheet target. Single optional so only one
    /// dialog is presented at a time, matching MessageRow's presentActions
    /// pattern.
    @State private var actionsTarget: MessageQueue.PendingMessage.ID?

    var body: some View {
        ForEach(messageManager.messageQueue.pendingFor(chatId: chatId)) { pending in
            let isFailed = pending.retryCount >= MessageQueue.maxRetries
            HStack {
                Spacer(minLength: AppConstants.UI.Bubble.spacerMinLength)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(pending.text)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 2) {
                        Image(systemName: isFailed ? "exclamationmark.circle" : "clock")
                            .font(.system(size: AppConstants.UI.FontSize.micro))
                        Text(isFailed ? L10n.string("Failed") : L10n.string("Sending..."))
                            .font(.system(size: AppConstants.UI.FontSize.tiny))
                    }
                    .foregroundStyle(isFailed ? WristTheme.Palette.danger.opacity(0.9) : .white.opacity(0.55))
                }
                .padding(.horizontal, AppConstants.UI.Bubble.horizontalPadding)
                .padding(.vertical, AppConstants.UI.Bubble.verticalPadding)
                .padding(.trailing, MessageBubbleShape.tailExtent)
                .background {
                    WristBubbleBackground(isOutgoing: true, color: isFailed ? WristTheme.Palette.danger.opacity(0.30) : WristTheme.Palette.outgoingBubblePending)
                }
                .onLongPressGesture {
                    guard isFailed else { return }
                    HapticManager.tap()
                    actionsTarget = pending.id
                }
            }
            .padding(AppConstants.UI.messageRowInsets)
            .confirmationDialog(
                L10n.string("Message failed"),
                isPresented: Binding(
                    get: { actionsTarget == pending.id },
                    set: { newValue in if !newValue { actionsTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.string("Retry")) {
                    messageManager.messageQueue.retryFailed(pending.id)
                    Task { await messageManager.flushMessageQueue() }
                }
                Button(L10n.string("Delete"), role: .destructive) {
                    messageManager.messageQueue.removeFailed(pending.id)
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            }
        }
    }
}
