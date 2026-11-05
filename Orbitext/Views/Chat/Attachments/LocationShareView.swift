import SwiftUI

struct LocationShareView: View {
    @Environment(MessageManager.self) private var messageManager
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64

    @State private var provider = LocationProvider()
    @State private var isSending = false
    @State private var sendFailed = false
    @State private var isVisible = false

    var body: some View {
        List {
            switch provider.state {
            case .idle, .requestingPermission, .locating:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.string(provider.state == .requestingPermission ? "Allow location access to continue." : "Finding your location…"))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .wristGlassRow()

                Button(L10n.string("Cancel")) {
                    provider.cancel()
                    dismiss()
                }
                .frame(minHeight: 44)
                .wristGlassRow()

            case .failed(let failure):
                Label(L10n.string(failure.messageKey), systemImage: "location.slash")
                    .font(.callout)
                    .wristGlassRow()
                Button(L10n.string("Retry")) { provider.request() }
                    .frame(minHeight: 44)
                    .wristGlassRow()

            case .ready(let location):
                LocationMessageView(latitude: location.latitude, longitude: location.longitude, livePeriod: nil)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .listRowBackground(Color.clear)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(location.latitude.formatted(.number.precision(.fractionLength(4)))), \(location.longitude.formatted(.number.precision(.fractionLength(4))))")
                        .font(.caption.monospacedDigit())
                    Text(L10n.format("Accuracy: ±%@ m", location.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L10n.string("Only this location is shared."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .wristGlassRow()

                if sendFailed {
                    Text(L10n.string("Location was not sent. Try again."))
                        .font(.caption)
                        .foregroundStyle(WristTheme.Palette.danger)
                        .wristGlassRow()
                }

                Button {
                    Task { await send(location) }
                } label: {
                    HStack {
                        if isSending { ProgressView() } else { Image(systemName: "paperplane.fill") }
                        Text(L10n.string(isSending ? "Sending location" : "Send location"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(WristTheme.Palette.accent)
                .disabled(isSending)
                .wristGlassRow()

                Button(L10n.string("Refresh location")) {
                    sendFailed = false
                    provider.request()
                }
                .frame(minHeight: 44)
                .disabled(isSending)
                .wristGlassRow()
            }
        }
        .navigationTitle(L10n.string("Location"))
        .wristListStyle()
        .onAppear {
            isVisible = true
            if provider.state == .idle { provider.request() }
        }
        .onDisappear {
            isVisible = false
            provider.cancel()
        }
    }

    @MainActor
    private func send(_ location: SharedLocation) async {
        guard !isSending else { return }
        isSending = true
        sendFailed = false
        defer { isSending = false }
        let sent = await messageManager.sendLocation(chatId: chatId, location: location)
        guard isVisible else { return }
        if sent { router.openChat(chatId) } else { sendFailed = true }
    }
}
