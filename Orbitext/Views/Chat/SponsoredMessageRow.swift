import SwiftUI

/// The channel's ad after its newest message (Telegram API Terms of Service
/// 3.3). Loads when the channel opens; a chat that is no channel asks for
/// nothing and draws nothing.
struct ChatSponsoredSection: View {
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(SponsoredMessageStore.self) private var store
    let chatId: Int64
    var fallback: ChatInfo?
    /// Follows the ad's link once the click is reported.
    let onOpen: (SponsoredMessage) async -> Void

    /// Kept here, not on the row: a reported ad leaves with its row.
    @State private var notice: String?

    private struct LoadID: Hashable {
        let chatId: Int64
        let isChannel: Bool
    }

    var body: some View {
        let isChannel = chatRepository.chat(id: chatId, fallback: fallback).isChannel
        // A stack, not a Group: an empty Group has no view to run the task on.
        VStack(spacing: 0) {
            if isChannel, let ad = store.message(for: chatId) {
                SponsoredMessageRow(ad: ad, onOpen: onOpen) { notice = $0 }
                    .padding(AppConstants.UI.compactRowInsets)
            }
        }
        .task(id: LoadID(chatId: chatId, isChannel: isChannel)) {
            await store.load(chatId: chatId, isChannel: isChannel)
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(L10n.string("OK"), role: .cancel) {}
        }
    }
}

/// A clearly labeled ad: "Sponsored" or "Recommended", its title and text,
/// the sponsor's details, the button, and a report option when TDLib allows
/// one. The view is reported once, when the whole row is on screen, which
/// is what viewMessages asks of an ad. The text is plain: a link in it would
/// open without the click report TDLib requires.
struct SponsoredMessageRow: View {
    @Environment(SponsoredMessageStore.self) private var store
    let ad: SponsoredMessage
    let onOpen: (SponsoredMessage) async -> Void
    /// The outcome of a report, for the user.
    let onNotice: (String) -> Void

    @State private var showsActions = false
    @State private var requiredOptions: RequiredOptions?

    private struct RequiredOptions: Identifiable {
        let title: String
        let options: [SponsoredReportOption]
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            textBlock
                // The text, without the button, is what has to be on screen.
                .onScrollVisibilityChange(threshold: 0.99) { isVisible in
                    guard isVisible else { return }
                    Task { await store.markViewed(ad) }
                }
            Button {
                Task { await onOpen(ad) }
            } label: {
                Text(ad.buttonText.isEmpty ? L10n.string("Open") : ad.buttonText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accentSoft))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { WristGlassBackground(cornerRadius: 16) }
        .accessibilityElement(children: .contain)
        .confirmationDialog(ad.label, isPresented: $showsActions) {
            Button(L10n.string("Report ad"), role: .destructive) { report(optionId: Data()) }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .sheet(item: $requiredOptions) { required in
            ReportOptionsView(title: required.title, options: required.options) { option in
                requiredOptions = nil
                report(optionId: option.id)
            }
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
                header
                if !ad.title.isEmpty {
                    Text(ad.title)
                        .font(.system(size: AppConstants.UI.FontSize.body + 3, weight: .semibold))
                        .foregroundStyle(WristTheme.Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !ad.text.isEmpty {
                    Text(ad.text.text)
                        .font(.footnote)
                        .foregroundStyle(WristTheme.Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach([ad.sponsorInfo, ad.additionalInfo].filter { !$0.isEmpty }, id: \.self) { info in
                    Text(info)
                        .font(.caption2)
                        .foregroundStyle(WristTheme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(ad.label)
                .font(.system(size: AppConstants.UI.FontSize.small, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(WristTheme.Palette.accent)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if ad.canBeReported {
                Button {
                    showsActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WristTheme.Palette.secondaryText)
                .accessibilityLabel(L10n.string("Ad options"))
            }
        }
    }

    private func report(optionId: Data) {
        Task {
            switch await store.report(ad, optionId: optionId) {
            case .reported: onNotice(L10n.string("Ad reported"))
            case .adsHidden: onNotice(L10n.string("Ads hidden"))
            case .premiumRequired: onNotice(L10n.string("Hiding ads requires Telegram Premium"))
            case .failed: onNotice(L10n.string("The ad could not be reported"))
            case .optionRequired(let title, let options):
                requiredOptions = RequiredOptions(title: title, options: options)
            }
        }
    }
}

/// The reasons TDLib offers for a report; picking one sends the report again.
private struct ReportOptionsView: View {
    let title: String
    let options: [SponsoredReportOption]
    let onSelect: (SponsoredReportOption) -> Void

    var body: some View {
        List {
            Section(title) {
                ForEach(options) { option in
                    Button(option.text) { onSelect(option) }
                }
            }
        }
    }
}
