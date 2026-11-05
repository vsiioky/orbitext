import SwiftUI

struct ConnectionBadge: View {
    let networkMonitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Image(systemName: symbolName)
                .font(.system(size: AppConstants.UI.FontSize.tiny))
                .foregroundStyle(statusColor)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusColor: Color {
        switch networkMonitor.connectionStatus {
        case .connected:
            WristTheme.Palette.success
        case .connecting:
            WristTheme.Palette.warning
        case .offline:
            WristTheme.Palette.danger
        }
    }

    private var symbolName: String {
        switch networkMonitor.connectionStatus {
        case .connected:
            networkMonitor.connectionType.iconName
        case .connecting, .offline:
            networkMonitor.connectionStatus.systemImage
        }
    }

    private var accessibilityLabel: String {
        switch networkMonitor.connectionStatus {
        case .connected:
            return L10n.format("Connected via %@", networkMonitor.connectionType.rawValue)
        case .connecting:
            return L10n.string("Connecting...")
        case .offline:
            return L10n.string("Offline")
        }
    }
}

struct ConnectionRingView: View {
    let networkMonitor: NetworkMonitor
    @State private var pulse = false
    @State private var showRing = false

    var body: some View {
        Group {
            if showRing, let style = ringStyle {
                GeometryReader { proxy in
                    let minSide = min(proxy.size.width, proxy.size.height)
                    let cornerRadius = minSide * 0.24
                    let outerWidth = max(6, minSide * 0.075)
                    let innerWidth = max(1.5, minSide * 0.014)

                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .inset(by: outerWidth * 0.45)
                            .strokeBorder(style.base.opacity(pulse ? 0.18 : 0.08), lineWidth: outerWidth)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .inset(by: innerWidth * 0.8)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        style.highlight.opacity(pulse ? 0.80 : 0.55),
                                        style.base.opacity(pulse ? 0.58 : 0.34)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: innerWidth
                            )
                    }
                    .padding(1)
                    .opacity(pulse ? 0.96 : 0.90)
                    .scaleEffect(pulse ? 1.0 : 0.992)
                    .onAppear {
                        withAnimation(.easeInOut(duration: style.pulseDuration).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onChange(of: networkMonitor.connectionStatus) { _, newStatus in
            if newStatus == .connected {
                withAnimation(.easeOut(duration: 0.3)) { showRing = false }
            }
        }
        .task(id: networkMonitor.connectionStatus) {
            if networkMonitor.connectionStatus != .connected {
                try? await Task.sleep(for: .seconds(5.0))
                guard !Task.isCancelled else { return }
                if networkMonitor.connectionStatus != .connected {
                    withAnimation(.easeIn(duration: 0.3)) { showRing = true }
                }
            }
        }
    }

    private var ringStyle: RingStyle? {
        switch networkMonitor.connectionStatus {
        case .connected:
            nil
        case .connecting:
            RingStyle(base: WristTheme.Palette.warning, highlight: WristTheme.Palette.warningHighlight, pulseDuration: 1.1)
        case .offline:
            RingStyle(base: WristTheme.Palette.danger, highlight: WristTheme.Palette.dangerHighlight, pulseDuration: 1.7)
        }
    }
}

private struct RingStyle {
    let base: Color
    let highlight: Color
    let pulseDuration: Double
}
