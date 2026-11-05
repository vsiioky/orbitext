import SwiftUI

/// What the user picked in the bot menu. ChatView acts on it after the
/// sheet is gone so navigation and dialogs do not race the dismissal.
enum BotMenuSelection: Equatable {
    case keyboardButton(ReplyKeyboardButton)
    case command(BotCommandInfo)
}

/// Bot menu opened from the composer: the bot's reply keyboard (the
/// keyboard Telegram shows in place of the system one) and its command list.
struct BotMenuView: View {
    @Environment(\.dismiss) private var dismiss
    let keyboard: ReplyKeyboard?
    let commands: [BotCommandInfo]
    let onSelect: (BotMenuSelection) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let keyboard, !keyboard.rows.isEmpty {
                        sectionHeader(L10n.string("Keyboard"))
                        keyboardRows(keyboard)
                    }
                    if !commands.isEmpty {
                        sectionHeader(L10n.string("Commands"))
                        ForEach(commands) { command in
                            commandRow(command)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(L10n.string("Bot menu"))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(WristTheme.Palette.secondaryText)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func keyboardRows(_ keyboard: ReplyKeyboard) -> some View {
        VStack(spacing: AppConstants.UI.BotKeyboard.spacing) {
            ForEach(keyboard.rows.indices, id: \.self) { row in
                HStack(spacing: AppConstants.UI.BotKeyboard.spacing) {
                    ForEach(keyboard.rows[row].indices, id: \.self) { column in
                        keyboardButton(keyboard.rows[row][column])
                    }
                }
            }
        }
    }

    private func keyboardButton(_ button: ReplyKeyboardButton) -> some View {
        Button {
            select(.keyboardButton(button))
        } label: {
            HStack(spacing: 3) {
                if let icon = Self.icon(for: button.kind) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
                Text(button.text)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: AppConstants.UI.BotKeyboard.buttonMinHeight + 6)
            .background(
                InlineKeyboardView.fill(for: button.style),
                in: RoundedRectangle(cornerRadius: AppConstants.UI.BotKeyboard.buttonCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!button.isSupported)
        .opacity(button.isSupported ? 1 : 0.45)
        .accessibilityLabel(button.text)
        .accessibilityHint(button.isSupported ? "" : L10n.string("Not available on Apple Watch"))
        .accessibilityIdentifier("bot-reply-keyboard-button")
    }

    private func commandRow(_ command: BotCommandInfo) -> some View {
        Button {
            select(.command(command))
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.messageText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WristTheme.Palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption2)
                        .foregroundStyle(WristTheme.Palette.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                WristTheme.Palette.surface,
                in: RoundedRectangle(cornerRadius: AppConstants.UI.BotKeyboard.buttonCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bot-command-button")
    }

    private func select(_ selection: BotMenuSelection) {
        HapticManager.tap()
        onSelect(selection)
        dismiss()
    }

    private static func icon(for kind: ReplyKeyboardButton.Kind) -> String? {
        switch kind {
        case .requestLocation: "location"
        case .requestPhoneNumber: "phone"
        case .text, .unsupported: nil
        }
    }
}
