import SwiftUI

struct ContactsView: View {
    @Environment(MessageManager.self) private var messageManager
    @State private var allContacts: [ContactInfo] = []
    @State private var searchText = ""
    @State private var didLoad = false

    var body: some View {
        List {
            Section {
                TextField(L10n.string("Name or username"), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .wristFieldRow()
            }

            if !didLoad {
                LoadingListRow()
                    .wristGlassRow()
            }

            if didLoad && filteredContacts.isEmpty {
                Group {
                    if searchText.isEmpty {
                        ContentUnavailableView(L10n.string("No Contacts"), systemImage: "person.2.slash")
                    } else {
                        ContentUnavailableView(L10n.string("No Results"), systemImage: "person.slash")
                    }
                }
                .wristGlassRow()
            }

            ForEach(filteredContacts) { contact in
                NavigationLink {
                    ContactDetailView(contact: contact)
                } label: {
                    ContactRow(contact: contact)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }
        }
        .wristListStyle()
        .navigationTitle(L10n.string("Contacts"))
        .task {
            // On watchOS avoid refreshing hundreds of contacts on every
            // screen open; manual cache clear still forces a fresh load.
            if let cached = messageManager.cachedContacts, !cached.isEmpty {
                allContacts = cached
                didLoad = true
                return
            }
            let fresh = await messageManager.loadContacts()
            allContacts = fresh
            didLoad = true
        }
    }

    private var filteredContacts: [ContactInfo] {
        guard !searchText.isEmpty else { return allContacts }
        let q = searchText.lowercased()
        return allContacts.filter {
            $0.fullName.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }
}

struct ContactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let contact: ContactInfo

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(
                title: contact.fullName,
                id: contact.id,
                photoFileId: contact.photoFileId,
                isOnline: contact.isOnline,
                size: AppConstants.UI.Avatar.contact
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.fullName)
                    .font(WristTheme.Typography.rowTitle)
                    .lineLimit(dynamicTypeSize >= .xxxLarge ? 2 : 1)

                Text(contact.statusText)
                    .font(WristTheme.Typography.rowMeta)
                    .foregroundStyle(contact.isOnline ? WristTheme.Palette.success : WristTheme.Palette.secondaryText)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }
}

struct ContactDetailView: View {
    let contact: ContactInfo

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(
                        title: contact.fullName,
                        id: contact.id,
                        photoFileId: contact.photoFileId,
                        isOnline: contact.isOnline,
                        size: AppConstants.UI.Avatar.profile
                    )
                    Text(contact.fullName)
                        .font(WristTheme.Typography.screenTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(contact.statusText)
                        .font(WristTheme.Typography.detail)
                        .foregroundStyle(contact.isOnline ? WristTheme.Palette.success : WristTheme.Palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }

            Section {
                if !contact.phone.isEmpty {
                    HStack {
                        Image(systemName: "phone")
                            .font(.caption2)
                        Text(contact.phone)
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }
                if !contact.username.isEmpty {
                    HStack {
                        Image(systemName: "at")
                            .font(.caption2)
                        Text(contact.username)
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }
            }

            Section {
                NavigationLink {
                    ComposeView(chatId: contact.id, opensPrivateChat: true)
                } label: {
                    HStack {
                        Image(systemName: "message")
                        Text(L10n.string("Send Message"))
                    }
                    .foregroundStyle(WristTheme.Palette.accent)
                    .font(WristTheme.Typography.capsule)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }
        }
        .wristListStyle()
    }
}
