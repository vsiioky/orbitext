import SwiftUI

/// The chat's title, profile button and "typing..." line. It reads the chat
/// from the directory, which changes for any chat, so it is a modifier of its
/// own: the screen under it is not redrawn when this is.
struct ChatNavigationChrome: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(AppRouter.self) private var router
    @Environment(ChatRepository.self) private var chatRepository
    let chatId: Int64
    /// What a route that carried the chat shows until the directory has it.
    var fallback: ChatInfo?

    func body(content: Content) -> some View {
        let chat = chatRepository.chat(id: chatId, fallback: fallback)
        content
            .navigationTitle(chat.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.push(.profile(chatRepository.chat(id: chatId, fallback: fallback)))
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel(L10n.string("Profile"))
                    .accessibilityIdentifier(appState.service.isSelfChat(chatId: chatId) ? "saved-messages-profile" : "chat-profile")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let subtitle = ChatActionSubtitle.text(for: chat) {
                    Text(subtitle)
                        .font(.system(size: AppConstants.UI.FontSize.small))
                        .foregroundStyle(WristTheme.Palette.accent)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                        .background { WristGlassBackground(cornerRadius: 12) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: chat.typingActionKind)
            .animation(.easeInOut(duration: 0.18), value: chat.typingUserNames)
    }
}

/// What the line under the title says while someone acts in the chat.
enum ChatActionSubtitle {
    static func text(for chat: ChatInfo) -> String? {
        let kind = chat.typingActionKind
        guard kind != .none, !chat.typingUserNames.isEmpty else { return nil }
        let names = chat.typingUserNames

        // In group chats, prefix the action verb with the actor's name so the
        // user can tell *who* is typing/recording. In 1:1 chats the title
        // already names the other side, so the bare verb stays readable.
        let showSender = chat.isGroup && !chat.isChannel
        let firstName = names.first ?? ""

        switch kind {
        case .typing:
            switch names.count {
            case 0: return L10n.string("typing...")
            case 1: return L10n.format("%@ typing...", firstName)
            case 2: return L10n.format("%@, %@ typing...", names[0], names[1])
            default: return L10n.format("%lld people typing...", Int64(names.count))
            }
        case .recordingVoice:
            return showSender ? L10n.format("%@ is recording voice...", firstName) : L10n.string("recording voice...")
        case .recordingVideo, .uploadingVideoNote:
            return showSender ? L10n.format("%@ is recording video...", firstName) : L10n.string("recording video...")
        case .uploadingPhoto:
            return showSender ? L10n.format("%@ is uploading photo...", firstName) : L10n.string("uploading photo...")
        case .uploadingVideo:
            return showSender ? L10n.format("%@ is uploading video...", firstName) : L10n.string("uploading video...")
        case .uploadingVoice:
            return showSender ? L10n.format("%@ is sending voice...", firstName) : L10n.string("sending voice...")
        case .uploadingDocument:
            return showSender ? L10n.format("%@ is sending file...", firstName) : L10n.string("sending file...")
        case .choosingSticker:
            return showSender ? L10n.format("%@ is choosing sticker...", firstName) : L10n.string("choosing sticker...")
        case .choosingLocation:
            return showSender ? L10n.format("%@ is choosing location...", firstName) : L10n.string("choosing location...")
        case .choosingContact:
            return showSender ? L10n.format("%@ is choosing contact...", firstName) : L10n.string("choosing contact...")
        case .playingGame:
            return showSender ? L10n.format("%@ is playing game...", firstName) : L10n.string("playing game...")
        case .none:
            return nil
        }
    }
}
