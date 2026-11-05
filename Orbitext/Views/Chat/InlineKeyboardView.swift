import SwiftUI

/// Inline keyboard under a bot message. It sits outside the bubble so the
/// bubble's double-tap / long-press gestures and its combined
/// accessibility element do not swallow the buttons.
struct InlineKeyboardView: View {
    let rows: [[InlineKeyboardButton]]
    var isEnabled = true
    let onTap: (InlineKeyboardButton) async -> Void

    private struct Position: Hashable {
        let row: Int
        let column: Int
    }

    /// One press at a time: callback answers can take seconds and a second
    /// tap would send a duplicate query.
    @State private var pendingPosition: Position?

    var body: some View {
        VStack(spacing: AppConstants.UI.BotKeyboard.spacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: AppConstants.UI.BotKeyboard.spacing) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        button(at: Position(row: row, column: column))
                    }
                }
            }
        }
        // A bot edit can replace the keyboard while a press is in flight;
        // the old position must not show progress on a different button.
        .onChange(of: rows) { pendingPosition = nil }
    }

    private func button(at position: Position) -> some View {
        let button = rows[position.row][position.column]
        let isPending = pendingPosition == position
        return Button {
            press(button, at: position)
        } label: {
            HStack(spacing: 2) {
                Text(button.text)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if button.opensLink {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppConstants.UI.FontSize.tiny, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .opacity(isPending ? 0 : 1)
            .overlay {
                if isPending { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: AppConstants.UI.BotKeyboard.buttonMinHeight)
            .background(
                Self.fill(for: button.style),
                in: RoundedRectangle(cornerRadius: AppConstants.UI.BotKeyboard.buttonCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppConstants.UI.BotKeyboard.buttonCornerRadius, style: .continuous)
                    .stroke(WristTheme.Palette.separator, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || pendingPosition != nil)
        .accessibilityLabel(button.text)
        .accessibilityIdentifier("bot-inline-button")
    }

    private func press(_ button: InlineKeyboardButton, at position: Position) {
        guard pendingPosition == nil else { return }
        HapticManager.tap()
        pendingPosition = position
        Task {
            await onTap(button)
            if pendingPosition == position { pendingPosition = nil }
        }
    }

    /// Flat fills like ReactionsBar: every history row is eager, so no
    /// per-button material blur.
    static func fill(for style: BotButtonStyle) -> Color {
        switch style {
        case .standard: WristTheme.Palette.raisedSurface
        case .primary: WristTheme.Palette.accent.opacity(0.35)
        case .danger: WristTheme.Palette.danger.opacity(0.3)
        case .success: WristTheme.Palette.success.opacity(0.3)
        }
    }
}
