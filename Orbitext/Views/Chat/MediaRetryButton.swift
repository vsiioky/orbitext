import SwiftUI

struct MediaRetryButton: View {
    let mode: MediaViewerMode
    var message: String?
    var actionTitle: String = L10n.string("Tap to retry")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                if let message {
                    Text(message)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                Text(actionTitle)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(minWidth: 100, minHeight: 64)
            .background { WristGlassBackground() }
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch mode {
        case .photo: "photo.badge.exclamationmark"
        case .video: "video.badge.ellipsis"
        }
    }
}
