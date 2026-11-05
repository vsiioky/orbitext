import SwiftUI

struct ProfileView: View {
    @Environment(MessageManager.self) private var messageManager
    let chat: ChatInfo

    @State private var contact: ContactInfo?
    @State private var groupInfo: GroupInfo?
    @State private var didLoad = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(
                        title: chat.title,
                        id: chat.id,
                        photoFileId: contact == nil ? chat.photoFileId : contact?.photoFileId,
                        isGroup: chat.isGroup,
                        isOnline: contact?.isOnline ?? false,
                        size: AppConstants.UI.Avatar.profile
                    )
                    Text(chat.title)
                        .font(WristTheme.Typography.screenTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !didLoad {
                        ProgressView()
                            .controlSize(.small)
                    } else if let contact {
                        Text(contact.statusText)
                            .font(WristTheme.Typography.detail)
                            .foregroundStyle(contact.isOnline ? WristTheme.Palette.success : WristTheme.Palette.secondaryText)
                    } else if chat.isChannel {
                        Text(L10n.string("Channel"))
                            .font(WristTheme.Typography.detail)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                    } else if chat.isGroup {
                        Text(L10n.string("Group"))
                            .font(WristTheme.Typography.detail)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }

            if let contact {
                Section {
                    if !contact.phone.isEmpty {
                        Label(contact.phone, systemImage: "phone")
                            .font(.caption)
                            .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                            .wristGlassRow()
                    }
                    if !contact.username.isEmpty {
                        Label("@\(contact.username)", systemImage: "at")
                            .font(.caption)
                            .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                            .wristGlassRow()
                    }
                }

                if !contact.firstName.isEmpty {
                    Section {
                        NavigationLink {
                            ComposeView(chatId: contact.id)
                        } label: {
                            Label(L10n.string("Send Message"), systemImage: "message")
                                .font(WristTheme.Typography.capsule)
                                .foregroundStyle(WristTheme.Palette.accent)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                        .wristGlassRow()
                    }
                }
            }

            if chat.isGroup || chat.isChannel, let info = groupInfo {
                Section {
                    if let count = info.memberCount {
                        Label(L10n.format("%lld members", Int64(count)), systemImage: "person.2")
                            .font(.caption)
                            .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                            .wristGlassRow()
                    }
                    if let desc = info.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowInsets(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                            .wristGlassRow()
                    }
                }
            }
        }
        .wristListStyle()
        .navigationTitle(L10n.string("Profile"))
        .task {
            if chat.isGroup || chat.isChannel {
                groupInfo = await messageManager.getGroupInfo(chatId: chat.id)
            } else {
                contact = await messageManager.loadContact(userId: chat.id)
            }
            didLoad = true
        }
    }
}
