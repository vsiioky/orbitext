import SwiftUI

/// Auth failures can include a recovery step and a diagnostic code. Allow the
/// entire message and Retry button to be reached on the smallest watch display.
struct AuthErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(WristTheme.Palette.danger)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)

                Button(L10n.string("Retry"), action: onRetry)
                    .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
                    .frame(minHeight: 44)
            }
            .padding(12)
            .background(WristGlassBackground())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
