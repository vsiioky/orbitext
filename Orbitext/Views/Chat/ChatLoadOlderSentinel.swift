import SwiftUI

/// Fires `onVisible` only when the load-older sentinel is at least 50%
/// inside the viewport, not when SwiftUI merely inserts it into the
/// hierarchy. Required because the eager VStack always materializes the
/// sentinel, and a plain .onAppear would yank older messages the moment
/// pagination flipped on - even if the sentinel sat far off-screen.
/// watchOS 11+. Falls back to .onAppear on watchOS 10 (best effort).
struct ChatLoadOlderSentinel: View {
    let onVisible: () -> Void

    var body: some View {
        Color.clear
            .frame(height: 30)
            .modifier(LoadOlderSentinelModifier(onVisible: onVisible))
    }
}

private struct LoadOlderSentinelModifier: ViewModifier {
    let onVisible: () -> Void

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollVisibilityChange(threshold: 0.5) { visible in
                if visible { onVisible() }
            }
        } else {
            content.onAppear { onVisible() }
        }
    }
}
