import SwiftUI

struct DateSeparatorView: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(label)
                .font(.system(size: AppConstants.UI.FontSize.small, weight: .medium))
                .foregroundStyle(WristTheme.Palette.secondaryText)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal, 8)
    }

    private var label: String {
        TimeFormatting.dateSeparator(date)
    }
}
