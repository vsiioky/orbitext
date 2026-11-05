import SwiftUI

struct ScrollToBottomButton: View {
    let unreadNewCount: Int
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "chevron.down")
            .font(.system(size: AppConstants.UI.FontSize.body, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background { WristGlassBackground(cornerRadius: 22, tint: WristTheme.Palette.accent) }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, AppConstants.UI.ScrollButton.bottomPadding)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(duration: 0.3), value: unreadNewCount)
        .accessibilityLabel(L10n.string("Scroll to bottom"))
        .accessibilityValue(unreadNewCount > 0 ? L10n.format("%lld new", Int64(unreadNewCount)) : "")
    }
}
