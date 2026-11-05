import SwiftUI

/// Outgoing-message status indicator. The view colors itself based on
/// `state` (red for .failed, white at 70% opacity otherwise) - callers
/// MUST NOT wrap it in foregroundStyle, or the failed-state red is lost.
struct StateIconView: View {
    typealias State = MessageDeliveryState

    let state: State
    var size: CGFloat = AppConstants.UI.FontSize.micro
    var tint: Color?

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size))
            .foregroundStyle(tint ?? defaultTint)
            .accessibilityLabel(state.accessibilityLabel)
    }

    private var symbolName: String {
        switch state {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var defaultTint: Color {
        switch state {
        case .failed: return .red
        default: return .white.opacity(0.7)
        }
    }
}

extension StateIconView {
    init(message: MessageInfo, size: CGFloat = AppConstants.UI.FontSize.micro) {
        self.init(state: message.deliveryState, size: size)
    }
}
