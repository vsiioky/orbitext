import SwiftUI

/// One slot on the keypad grid.
enum KeypadKey: Hashable {
    case digit(String)
    case special(String)
    case delete
    case empty

    var label: String? {
        switch self {
        case .digit(let s), .special(let s): return s
        default: return nil
        }
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// Generic 3x4 numeric keypad. Renders the 12 slots passed in `keys`
/// (row-major) and invokes `onKey` on tap with haptic feedback.
struct KeypadView: View {
    let keys: [KeypadKey]
    let onKey: (KeypadKey) -> Void

    private var keyMinHeight: CGFloat { AppConstants.UI.Keypad.keyHeight }
    private var gridSpacing: CGFloat { AppConstants.UI.Keypad.spacing }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                keyButton(key, row: index / 3, col: index % 3)
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: KeypadKey, row: Int, col: Int) -> some View {
        if key.isEmpty {
            Color.clear.frame(height: keyMinHeight)
        } else {
            let button = Button {
                HapticManager.tap()
                onKey(key)
            } label: {
                keyLabel(key)
                    .frame(maxWidth: .infinity, minHeight: keyMinHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeypadButtonStyle(row: row, col: col))
            .accessibilityLabel(accessibilityLabel(for: key))
            .accessibilityHint(accessibilityHint(for: key))

            if case .delete = key {
                button.buttonRepeatBehavior(.enabled)
            } else {
                button
            }
        }
    }

    @ViewBuilder
    private func keyLabel(_ key: KeypadKey) -> some View {
        switch key {
        case .digit(let s), .special(let s):
            Text(s)
                .font(.system(size: AppConstants.UI.Keypad.digitFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(WristTheme.Palette.primaryText)
        case .delete:
            Image(systemName: "delete.left")
                .font(.system(size: AppConstants.UI.Keypad.deleteIconSize, weight: .medium))
                .foregroundStyle(WristTheme.Palette.primaryText)
        case .empty:
            EmptyView()
        }
    }

    private func accessibilityLabel(for key: KeypadKey) -> String {
        switch key {
        case .digit(let s): return s
        case .special("+"): return L10n.string("Plus, country code prefix")
        case .special(let s): return s
        case .delete: return L10n.string("Delete")
        case .empty: return ""
        }
    }

    private func accessibilityHint(for key: KeypadKey) -> String {
        switch key {
        case .delete: return L10n.string("Removes last digit")
        default: return ""
        }
    }
}

private struct KeypadButtonStyle: ButtonStyle {
    let row: Int
    let col: Int

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // 1.3x is calmer on watchOS small screens.
        // Offset nudges the pressed key toward the nearest edge so the
        // tap feels directional; middle rows nudge down slightly.
        return configuration.label
            .background(
                WristGlassBackground(
                    cornerRadius: 14,
                    isSelected: pressed,
                    tint: pressed ? WristTheme.Palette.accent : nil
                )
            )
            .scaleEffect(pressed ? 1.3 : 1)
            .offset(
                x: pressed ? (col == 0 ? -2 : (col == 2 ? 2 : 0)) : 0,
                y: pressed ? ((row == 1 || row == 2) ? 1 : 0) : 0
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.6),
                       value: pressed)
            .zIndex(pressed ? 1 : 0)
    }
}
