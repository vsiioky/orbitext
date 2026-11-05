import SwiftUI

/// Settings -> Open-Source Licenses: the notices and license texts of the
/// third-party code in the app, and where its source code is.
struct OpenSourceLicensesView: View {
    var body: some View {
        List {
            Section {
                documentLink(.thirdPartyNotices, systemImage: "doc.text")
                documentLink(.appLicense, systemImage: "checkmark.seal")
                NavigationLink {
                    BotLinkView(url: AppConstants.App.sourceCodeURL)
                } label: {
                    Label(L10n.string("Source Code"), systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }

            Section(L10n.string("Licenses")) {
                ForEach(LicenseDocument.components) { document in
                    documentLink(document, systemImage: nil)
                }
            }
        }
        .wristListStyle()
        .navigationTitle(L10n.string("Open-Source Licenses"))
    }

    private func documentLink(_ document: LicenseDocument, systemImage: String?) -> some View {
        NavigationLink {
            LicenseTextView(document: document)
        } label: {
            if let systemImage {
                Label(document.displayTitle, systemImage: systemImage)
                    .font(.caption)
            } else {
                Text(document.displayTitle)
                    .font(.caption)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
        .wristGlassRow()
    }
}

/// One license text, reflowed for the watch. The text is read when the page
/// opens, not when the list builds its rows.
struct LicenseTextView: View {
    private enum Content {
        case loading
        case text([LicenseParagraph])
        case missing
    }

    let document: LicenseDocument
    @State private var content = Content.loading

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                switch content {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .text(let paragraphs):
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph.text)
                            .font(paragraph.isHeading ? .caption.bold() : .caption2)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .missing:
                    Text(L10n.string("License text is missing."))
                        .font(.caption2)
                        .foregroundStyle(WristTheme.Palette.warning)
                }
            }
            .padding(12)
            .background { WristGlassBackground() }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .navigationTitle(document.displayTitle)
        .background { WristScreenBackground() }
        .task {
            content = document.loadText(from: .main).map { .text(LicenseText.paragraphs($0)) } ?? .missing
        }
    }
}
