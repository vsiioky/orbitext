import SwiftUI

/// Numbered step row used in the QR login tutorial. The numbered circle
/// marks each step; text wraps within its column.
struct StepView: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(WristTheme.Palette.unreadBadge))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(WristTheme.Palette.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
