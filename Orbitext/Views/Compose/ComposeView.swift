import SwiftUI

struct ComposeView: View {
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(MessageManager.self) private var messageManager
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    /// Writing to a contact: their private chat may not exist yet.
    var opensPrivateChat = false
    var replyToId: Int64?
    var replyToSenderName: String?
    var replyToPreview: String?

    @State private var text = ""
    @State private var isSending = false
    @State private var isVisible = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var typingHeartbeatTask: Task<Void, Never>?

    private var quickReplies: [String] {
        [
            L10n.string("OK"),
            L10n.string("Thanks!"),
            L10n.string("On my way"),
            L10n.string("Call you later"),
            L10n.string("Yes"),
            L10n.string("No")
        ]
    }
    private let quickEmojis = ["👍", "❤️", "🔥", "😂", "🙏", "👌"]

    var body: some View {
        List {
            // Section 1: Reply context + input + send
            Section {
                if let name = replyToSenderName {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(WristTheme.Palette.accent)
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(size: AppConstants.UI.FontSize.small, weight: .semibold))
                                .foregroundStyle(WristTheme.Palette.accent)
                            if let preview = replyToPreview {
                                Text(preview)
                                    .font(.system(size: AppConstants.UI.FontSize.small))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .accessibilityLabel(preview.speakingSpoilerMasks)
                            }
                        }
                    }
                    .frame(height: 28)
                    .wristGlassRow()
                }

                TextField(L10n.string("Message"), text: $text)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                    .onChange(of: text) {
                        if text.count > AppConstants.Message.charLimit {
                            text = String(text.prefix(AppConstants.Message.charLimit))
                        }
                        scheduleDraftSave()
                        updateTypingHeartbeat()
                    }
                    .clipShape(Capsule())
                    .wristGlassRow()

                if text.count > AppConstants.Message.charWarningThreshold {
                    Text("\(text.count)/\(AppConstants.Message.charLimit)")
                        .font(.system(size: AppConstants.UI.FontSize.small))
                        .foregroundStyle(text.count > AppConstants.Message.charDangerThreshold ? WristTheme.Palette.danger : WristTheme.Palette.secondaryText)
                        .listRowBackground(Color.clear)
                }

                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                            Text(L10n.string("Send"))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .foregroundStyle(WristTheme.Palette.accent)
                .accessibilityLabel(isSending ? L10n.string("Sending message") : L10n.string("Send message"))
                .wristGlassRow()
            }

            Section(L10n.string("Quick replies")) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        HapticManager.tap()
                        text = ComposeDraft.appending(reply, to: text)
                    } label: {
                        Text(reply)
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(isSending)
                    .wristGlassRow()
                }
            }

            Section(L10n.string("Emoji")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 8) {
                    ForEach(quickEmojis, id: \.self) { emoji in
                        Button {
                            HapticManager.tap()
                            text = ComposeDraft.appending(emoji, to: text)
                        } label: {
                            Text(emoji)
                                .font(.title3)
                                .frame(minWidth: 40, minHeight: 44)
                                .background(WristGlassBackground(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(replyToId != nil ? L10n.string("Reply") : L10n.string("Message"))
        .wristListStyle()
        .onAppear {
            isVisible = true
            if let draft = chatRepository.getDraft(chatId: chatId), text.isEmpty {
                text = draft
            }
        }
        .onDisappear {
            isVisible = false
            cancelTransientTasks()
            persistDraft(text)
        }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let draftText = text
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppConstants.Draft.changeDebounce))
            guard !Task.isCancelled else { return }
            persistDraft(draftText)
        }
    }

    private func persistDraft(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        chatRepository.saveDraft(chatId: chatId, text: trimmed.isEmpty ? nil : trimmed)
    }

    private func cancelTransientTasks() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        stopTypingHeartbeat()
    }

    /// Keeps the remote typing indicator alive while the user is composing.
    /// TDLib's sendChatAction expires server-side after roughly 5s, so we
    /// re-send every 1s while the field is non-empty. The task is torn down
    /// the moment the text becomes empty (or the view disappears) so the
    /// indicator does not stay on forever.
    private func updateTypingHeartbeat() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            stopTypingHeartbeat()
            return
        }
        guard typingHeartbeatTask == nil else { return }
        let chatId = chatId
        let manager = messageManager
        typingHeartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                await manager.sendTyping(chatId: chatId)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTypingHeartbeat() {
        typingHeartbeatTask?.cancel()
        typingHeartbeatTask = nil
    }

    private func send() async {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !isSending else { return }
        isSending = true
        persistDraft(text)
        let outcome = await messageManager.sendMessage(
            chatId: chatId, text: msg, replyToMessageId: replyToId, opensPrivateChat: opensPrivateChat
        )
        // A refused message keeps its draft so it can be fixed and resent.
        guard outcome.wasAccepted else {
            isSending = false
            return
        }
        // Clear draft only after send is accepted locally (sent or queued).
        cancelTransientTasks()
        if ComposeDraft.matchesSubmitted(chatRepository.getDraft(chatId: chatId), submitted: msg) {
            chatRepository.saveDraft(chatId: chatId, text: nil)
            if ComposeDraft.matchesSubmitted(text, submitted: msg) { text = "" }
        }
        isSending = false
        if isVisible { dismiss() }
    }
}
