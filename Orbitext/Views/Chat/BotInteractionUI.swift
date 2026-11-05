import SwiftUI

/// Presentation state for bot interactions on the chat screen.
struct ChatBotUIState {
    enum Sheet: Identifiable {
        case menu
        case link(URL)

        var id: String {
            switch self {
            case .menu: "menu"
            case .link(let url): "link:\(url.absoluteString)"
            }
        }
    }

    var sheet: Sheet?
    var alertText: String?
    /// Neutral, auto-dismissing notice. ErrorPresenter's toast is red and
    /// reserved for errors, so callback answers need their own surface.
    var notice: String?
    var pendingSelection: BotMenuSelection?
    var confirmsPhoneShare = false
}

extension View {
    func botInteractionPresentation(
        state: Binding<ChatBotUIState>,
        keyboard: ReplyKeyboard?,
        commands: [BotCommandInfo],
        onSheetDismissed: @escaping () -> Void,
        onSharePhone: @escaping () -> Void
    ) -> some View {
        modifier(BotInteractionPresentation(
            state: state,
            keyboard: keyboard,
            commands: commands,
            onSheetDismissed: onSheetDismissed,
            onSharePhone: onSharePhone
        ))
    }
}

private struct BotInteractionPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var state: ChatBotUIState
    let keyboard: ReplyKeyboard?
    let commands: [BotCommandInfo]
    let onSheetDismissed: () -> Void
    let onSharePhone: () -> Void

    private var showsAlert: Binding<Bool> {
        Binding(
            get: { state.alertText != nil },
            set: { if !$0 { state.alertText = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.sheet, onDismiss: onSheetDismissed) { sheet in
                switch sheet {
                case .menu:
                    BotMenuView(keyboard: keyboard, commands: commands) { state.pendingSelection = $0 }
                case .link(let url):
                    BotLinkView(url: url)
                }
            }
            .alert(L10n.string("Bot"), isPresented: showsAlert) {
                Button(L10n.string("OK"), role: .cancel) {}
            } message: {
                Text(state.alertText ?? "")
            }
            .confirmationDialog(
                L10n.string("Share phone number?"),
                isPresented: $state.confirmsPhoneShare,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Share")) { onSharePhone() }
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("The bot will receive your phone number."))
            }
            .overlay(alignment: .top) {
                if let notice = state.notice {
                    Text(notice)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        // Opaque: material over the dark chat backdrop left
                        // the text unreadable on top of message bubbles.
                        .background(WristTheme.Palette.noticeBackground, in: Capsule())
                        .overlay { Capsule().stroke(WristTheme.Palette.separator, lineWidth: 0.5) }
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { state.notice = nil }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.notice)
            .task(id: state.notice) {
                guard state.notice != nil else { return }
                try? await Task.sleep(for: .seconds(AppConstants.UI.BotKeyboard.noticeDuration))
                guard !Task.isCancelled else { return }
                state.notice = nil
            }
    }
}
