import SwiftUI

/// A watch text field presents the system keyboard/dictation editor when tapped.
/// Keeping the bar mounted while hidden preserves its draft and in-flight send.
struct ChatComposerBar: View {
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(MessageManager.self) private var messageManager
    let chatId: Int64
    /// SF Symbol of the bot menu button; nil hides the button.
    var botMenuIcon: String?
    /// Highlights the bot menu button while the bot has a reply keyboard up.
    var isBotKeyboardActive = false
    /// Bot-supplied input_field_placeholder.
    var placeholder: String?
    /// Set while a bot's force-reply request is active.
    var replyToMessageId: Int64?
    let onAttach: () -> Void
    var onBotMenu: () -> Void = {}
    /// Called after a send was accepted (sent or queued).
    var onSent: () -> Void = {}

    @State private var text = ""
    @State private var isSending = false
    @State private var draftTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onAttach) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 44)
                    .background { WristGlassBackground(cornerRadius: 22) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Attach"))
            .disabled(isSending)

            if let botMenuIcon {
                Button(action: onBotMenu) {
                    Image(systemName: botMenuIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isBotKeyboardActive ? WristTheme.Palette.accent : WristTheme.Palette.primaryText)
                        .frame(width: AppConstants.UI.BotKeyboard.menuButtonWidth, height: 44)
                        .background { WristGlassBackground(cornerRadius: 22) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Bot menu"))
                .accessibilityIdentifier("bot-menu-button")
                .disabled(isSending)
            }

            TextField(placeholder ?? L10n.string("Reply…"), text: $text)
                .font(.body)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .frame(height: 44)
                .background { WristGlassBackground(cornerRadius: 22) }
                .clipShape(Capsule())
                .disabled(isSending)
                .accessibilityLabel(L10n.string("Reply"))
                .onSubmit { Task { await send() } }
                .onChange(of: text) {
                    if text.count > AppConstants.Message.charLimit {
                        text = String(text.prefix(AppConstants.Message.charLimit))
                    }
                    scheduleDraftSave()
                }
                .overlay {
                    if isSending {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityLabel(L10n.string("Sending message"))
                    }
                }
        }
        .onAppear { text = chatRepository.getDraft(chatId: chatId) ?? "" }
        .onDisappear {
            draftTask?.cancel()
            saveDraft()
        }
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppConstants.Draft.changeDebounce))
            guard !Task.isCancelled else { return }
            saveDraft()
        }
    }

    private func saveDraft() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        chatRepository.saveDraft(chatId: chatId, text: value.isEmpty ? nil : value)
    }

    private func send() async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        draftTask?.cancel()
        saveDraft()
        let outcome = await messageManager.sendMessage(chatId: chatId, text: value, replyToMessageId: replyToMessageId)
        // A refused message keeps its draft so it can be fixed and resent.
        guard outcome.wasAccepted else { return }
        onSent()
        if ComposeDraft.matchesSubmitted(chatRepository.getDraft(chatId: chatId), submitted: value) {
            chatRepository.saveDraft(chatId: chatId, text: nil)
            if ComposeDraft.matchesSubmitted(text, submitted: value) { text = "" }
        }
    }
}
