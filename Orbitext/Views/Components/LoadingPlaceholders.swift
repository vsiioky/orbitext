import SwiftUI

/// Compact full-area loading state for watchOS screens.
struct LoadingPlaceholderView: View {
    var message: String = L10n.string("Loading")

    var body: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(message)
                .font(.system(size: AppConstants.UI.FontSize.small))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(message)
    }
}

/// Centered loading indicator for use inside `List` sections.
struct LoadingListRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .accessibilityLabel(L10n.string("Loading"))
    }
}
