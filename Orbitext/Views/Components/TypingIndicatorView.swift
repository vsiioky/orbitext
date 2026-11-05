import SwiftUI

struct TypingIndicatorView: View {
    let names: [String]

    @State private var dotOffset: [CGFloat] = [0, 0, 0]

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(WristTheme.Palette.accent)
                        .frame(width: 4, height: 4)
                        .offset(y: dotOffset[i])
                }
            }

            Text(typingText)
                .font(.system(size: AppConstants.UI.FontSize.small))
                .foregroundStyle(WristTheme.Palette.secondaryText)
                .lineLimit(1)
        }
        .onAppear { startAnimation() }
    }

    private var typingText: String {
        switch names.count {
        case 0:
            return L10n.string("typing...")
        case 1:
            return L10n.format("%@ typing...", names[0])
        case 2:
            return L10n.format("%@, %@ typing...", names[0], names[1])
        default:
            return L10n.format("%lld people typing...", Int64(names.count))
        }
    }

    private func startAnimation() {
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(Double(i) * 0.15)
            ) {
                dotOffset[i] = -3
            }
        }
    }
}
