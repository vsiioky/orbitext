import os
import SwiftUI

struct ChatListView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppRouter.self) private var router
    @Environment(ChatRepository.self) private var chatRepository
    @State private var showFolderPicker = false

    var body: some View {
        @Bindable var router = router
        let loadingState = chatRepository.chatListLoadingState
        NavigationStack(path: $router.path) {
            List {
                let sections = ChatListSections(chats: filteredChats)
                let footerState = ChatListLoadMoreFooterState(
                    canLoadMore: chatRepository.canLoadMoreChats,
                    sectionsAreEmpty: sections.isEmpty,
                    loadingState: loadingState,
                    isPreparingNextPage: chatRepository.isPreparingNextChatPage
                )
                let emptyState = ChatListEmptyState(
                    sectionsAreEmpty: sections.isEmpty,
                    initialSyncComplete: chatRepository.isInitialSyncComplete,
                    loadingState: loadingState
                )

                listControls

                // Skeleton while first load
                if emptyState == .loading {
                    ForEach(0..<5, id: \.self) { _ in
                        ChatRowSkeletonView()
                            .listRowBackground(Color.clear)
                    }
                }

                if emptyState == .empty {
                    ContentUnavailableView(L10n.string("No Chats"), systemImage: "message")
                        .listRowBackground(Color.clear)
                }

                // Keep pinned chats first; the pin lives inside each card so
                // a separate section heading does not crowd the watch screen.
                ForEach(sections.pinned + sections.regular) { chat in
                    ChatListRow(chat: chat)
                }

                // Load more button
                switch footerState {
                case .hidden:
                    EmptyView()
                case .loading:
                    ChatListLoadMoreLoadingRow()
                        .id("chat-list-load-more-loading-row")
                case .button:
                    Button {
                        Task {
                            await chatRepository.loadMoreChats()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label(L10n.string("Load More"), systemImage: "arrow.down.circle")
                                .font(.caption)
                            Spacer()
                        }
                    }
                }
            }
            // Keep continuous scrolling: carousel layout/snapping adds CPU
            // work on every drag without changing the content of these cards.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { WristScreenBackground() }
            .navigationTitle(L10n.string("Chats"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: AppDestination.settings) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel(L10n.string("Settings"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: AppDestination.contacts) {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel(L10n.string("Contacts"))
                }
            }
            .navigationDestination(for: AppDestination.self) { destination in
                switch destination {
                case .chat(let chatId):
                    // Do NOT pass `initialChat` here. The closure
                    // re-evaluates whenever `chatRepository.chats`
                    // changes (e.g. when the user sends a message and
                    // lastMessage updates) and a fresh ChatInfo would
                    // produce a "different" ChatView struct each time -
                    // causing SwiftUI to remount the destination, which
                    // resets the ScrollView to content_offset 0 (oldest
                    // messages visible at top) on every send. ChatView's
                    // `currentChat` computed property reads the live
                    // value from chatRepository.chats anyway.
                    ChatView(chatId: chatId)
                case .compose(let target):
                    ComposeView(chatId: target.chatId, replyToId: target.replyToId, replyToSenderName: target.replyToSenderName, replyToPreview: target.replyToPreview)
                case .voiceRecorder(let chatId): VoiceRecorderView(chatId: chatId)
                case .profile(let chat): ProfileView(chat: chat)
                case .contacts: ContactsView()
                case .contactDetail(let contact): ContactDetailView(contact: contact)
                case .settings: SettingsView()
                case .search: SearchView()
                case .searchResult(let chat, let messageId):
                    ChatView(chatId: chat.id, initialChat: chat, scrollToMessageId: messageId)
                case .resolvedChat(let chat):
                    // The ChatInfo is fixed in the path, so unlike `.chat`
                    // it cannot remount ChatView when the chat list changes.
                    ChatView(chatId: chat.id, initialChat: chat)
                case .attachments(let chatId): ChatAttachmentsView(chatId: chatId)
                case .stickerPicker(let chatId): StickerPickerView(chatId: chatId)
                case .locationShare(let chatId): LocationShareView(chatId: chatId)
                case .mediaViewer(let fileId): MediaViewer(fileId: fileId)
                }
            }
            .task {
                Logger.app.debug(
                    "ChatListView.task start; chats=\(chatRepository.chats.count) initialSync=\(chatRepository.isInitialSyncComplete) authReady=\(appState.authManager.authState == .ready)"
                )
                if chatRepository.chats.isEmpty {
                    await appState.ensureVisibleContentLoaded()
                    Logger.app.debug(
                        "ChatListView.task finished initial load; chats=\(chatRepository.chats.count) initialSync=\(chatRepository.isInitialSyncComplete)"
                    )
                } else {
                    Logger.app.debug("ChatListView.task skipped initial load because chats already present")
                    chatRepository.prepareNextChatPageIfNeeded()
                }
            }
            .refreshable {
                await appState.refreshVisibleContent(
                    includeFolders: chatRepository.folderFilterEnabled,
                    flushMessageQueue: true
                )
            }
            .sheet(isPresented: $showFolderPicker) {
                ChatFolderPickerView(onSelect: selectFolder)
            }
        }
    }

    private var filteredChats: [ChatInfo] {
        chatRepository.filteredChats
    }

    private var activeFolderTitle: String {
        chatRepository.folders.first(where: { $0.id == chatRepository.activeFolderId })?.title
            ?? L10n.string("All Chats")
    }

    private var listControls: some View {
        HStack(spacing: 6) {
            Button {
                showFolderPicker = true
            } label: {
                HStack(spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                                .foregroundStyle(WristTheme.Palette.accent)
                            Text(activeFolderTitle)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        // Keep the folder name on one line on smaller watches;
                        // the picker and accessibility label expose its full text.
                        Text(activeFolderTitle)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(WristTheme.Typography.capsule)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background { WristGlassBackground(cornerRadius: 22) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(L10n.string("Folder")): \(activeFolderTitle)")

            NavigationLink(value: AppDestination.search) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .background { WristGlassBackground(cornerRadius: 22) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Search messages"))
        }
        .foregroundStyle(WristTheme.Palette.primaryText)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))
    }

    private func selectFolder(_ folderId: Int64?) {
        if let folderId {
            chatRepository.folderFilterEnabled = true
            chatRepository.selectedFolderId = folderId
        } else {
            chatRepository.folderFilterEnabled = false
        }
        showFolderPicker = false
        Task { await appState.refreshVisibleContent(includeFolders: false) }
    }
}

private struct ChatFolderPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatRepository.self) private var chatRepository
    let onSelect: (Int64?) -> Void

    var body: some View {
        NavigationStack {
            List {
                folderButton(title: L10n.string("All Chats"), folderId: nil)
                ForEach(chatRepository.folders) { folder in
                    folderButton(title: folder.title, folderId: folder.id)
                }
                if chatRepository.isLoadingFolders || !chatRepository.didAttemptFolderLoad {
                    LoadingListRow()
                } else if chatRepository.folders.isEmpty {
                    Text(L10n.string("No folders"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .wristListStyle()
            .navigationTitle(L10n.string("Folder"))
            .task { await appState.loadFoldersIfNeeded() }
            .refreshable { await chatRepository.loadFolders() }
        }
    }

    private func folderButton(title: String, folderId: Int64?) -> some View {
        Button {
            onSelect(folderId)
        } label: {
            HStack {
                Text(title)
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if chatRepository.activeFolderId == folderId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(WristTheme.Palette.accent)
                }
            }
        }
        .listRowBackground(WristGlassBackground(isSelected: chatRepository.activeFolderId == folderId))
        .accessibilityAddTraits(chatRepository.activeFolderId == folderId ? .isSelected : [])
    }
}

enum ChatListEmptyState: Equatable {
    case hidden
    case loading
    case empty

    init(sectionsAreEmpty: Bool, initialSyncComplete: Bool, loadingState: ChatListLoadingState) {
        guard sectionsAreEmpty else {
            self = .hidden
            return
        }
        if loadingState == .initial || !initialSyncComplete {
            self = .loading
        } else {
            self = .empty
        }
    }
}

enum ChatListLoadMoreFooterState: Equatable {
    case hidden
    case loading
    case button

    init(
        canLoadMore: Bool,
        sectionsAreEmpty: Bool,
        loadingState: ChatListLoadingState,
        isPreparingNextPage: Bool = false
    ) {
        guard !sectionsAreEmpty else {
            self = .hidden
            return
        }
        if loadingState == .pagination || isPreparingNextPage {
            self = .loading
        } else if canLoadMore {
            self = .button
        } else {
            self = .hidden
        }
    }
}

private struct ChatListLoadMoreLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.string("Loading"))
            Spacer()
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .wristGlassRow()
    }
}

struct ChatListSections: Equatable {
    let pinned: [ChatInfo]
    let regular: [ChatInfo]

    init(chats: [ChatInfo]) {
        pinned = chats.filter(\.isPinned)
        regular = chats.filter { !$0.isPinned }
    }

    var isEmpty: Bool {
        pinned.isEmpty && regular.isEmpty
    }
}

private struct ChatListRow: View {
    @Environment(ChatRepository.self) private var chatRepository
    let chat: ChatInfo

    var body: some View {
        NavigationLink(value: AppDestination.chat(chat.id)) {
            ChatRowView(chat: chat)
        }
        .accessibilityIdentifier(chatRepository.service.isSelfChat(chatId: chat.id) ? "saved-messages-row" : "chat-row")
        .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
        .listRowBackground(WristGlassBackground())
        .swipeActions(edge: .trailing) {
            Button {
                Task {
                    do {
                        try await chatRepository.muteChat(chatId: chat.id, isMuted: !chat.isMuted)
                    } catch {
                        Logger.app.warning("muteChat failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Label(chat.isMuted ? L10n.string("Unmute") : L10n.string("Mute"),
                      systemImage: chat.isMuted ? "bell" : "bell.slash")
            }
            .tint(chat.isMuted ? WristTheme.Palette.success : WristTheme.Palette.raisedSurface)

            Button {
                Task {
                    do {
                        try await chatRepository.pinChat(chatId: chat.id, isPinned: !chat.isPinned)
                    } catch {
                        Logger.app.warning("pinChat failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Label(chat.isPinned ? L10n.string("Unpin") : L10n.string("Pin"),
                      systemImage: chat.isPinned ? "pin.slash" : "pin")
            }
            .tint(WristTheme.Palette.warning)
        }
        .swipeActions(edge: .leading) {
            if chat.unreadCount > 0, let lastId = chat.lastMessage?.id {
                Button {
                    Task { await chatRepository.markAsRead(chatId: chat.id, messageId: lastId) }
                } label: {
                    Label(L10n.string("Mark Read"), systemImage: "checkmark.circle")
                }
                .tint(WristTheme.Palette.accent)
            }
        }
    }
}

struct ChatRowSkeletonView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(WristTheme.Palette.raisedSurface)
                .frame(width: AppConstants.UI.Skeleton.avatarSize, height: AppConstants.UI.Skeleton.avatarSize)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(WristTheme.Palette.raisedSurface)
                    .frame(width: 80, height: 9)
                RoundedRectangle(cornerRadius: 3)
                    .fill(WristTheme.Palette.surface)
                    .frame(width: 120, height: 8)
            }
            Spacer()
        }
        .opacity(0.68)
    }
}
