import SwiftUI

struct MessageSkeletonView: View {
    private let isOutgoing = Bool.random()

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: AppConstants.UI.Skeleton.spacerMinLength) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(WristTheme.Palette.raisedSurface)
                    .frame(width: CGFloat.random(in: 60...110), height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(WristTheme.Palette.surface)
                    .frame(width: CGFloat.random(in: 40...80), height: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                WristTheme.Palette.mutedSurface,
                in: RoundedRectangle(cornerRadius: 10)
            )
            if !isOutgoing { Spacer(minLength: AppConstants.UI.Skeleton.spacerMinLength) }
        }
        .opacity(0.65)
    }
}
