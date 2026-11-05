import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(MessageManager.self) private var messageManager
    @Environment(NetworkMonitor.self) private var networkMonitor
    @State private var showLogoutConfirm = false
    @AppStorage(MessageNotificationPreference.storageKey)
    private var notificationsEnabled = MessageNotificationPreference.defaultEnabled
    @State private var notificationPermissionGranted: Bool?
    @State private var floodWaitRemaining: Int?
    @State private var supportResolving = false
    @State private var supportError: String?
    @State private var suppressedSelectedFolderRefreshId: Int64?
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(QuickReactionPreference.storageKey) private var quickReaction = QuickReactionPreference.defaultEmoji

    var body: some View {
        @Bindable var chatRepo = chatRepository
        // No inner NavigationStack: SettingsView is pushed onto the root
        // stack from ChatListView. A nested stack swallows the push and
        // the page appears not to open on watchOS.
        List {
                // Connection
                Section(L10n.string("Connection")) {
                    HStack {
                        ConnectionBadge(networkMonitor: networkMonitor)
                        Text(connectionLabel)
                            .font(.caption)
                        Spacer()
                        if messageManager.messageQueue.hasPending {
                            Text(L10n.format("%lld queued", Int64(messageManager.messageQueue.pendingMessages.count)))
                                .font(.caption2)
                                .foregroundStyle(WristTheme.Palette.warning)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                    if let remaining = floodWaitRemaining {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(WristTheme.Palette.warning)
                                .font(.caption2)
                            Text(L10n.format("FLOOD_WAIT - %@", formatFloodWait(remaining)))
                                .font(.caption2)
                                .foregroundStyle(WristTheme.Palette.warning)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                        .wristGlassRow()
                    }
                }

                // Notifications
                Section {
                    Toggle(isOn: $notificationsEnabled) {
                        Label(L10n.string("Messages"), systemImage: "bell")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                    .onChange(of: notificationsEnabled) {
                        if notificationsEnabled {
                            Task {
                                await appState.notificationManager.requestPermission()
                                notificationPermissionGranted = appState.notificationManager.isAuthorized
                            }
                        }
                    }
                } header: {
                    Text(L10n.string("Notifications"))
                } footer: {
                    if notificationsEnabled, notificationPermissionGranted == false {
                        Text(L10n.string("System notification permission is not granted."))
                    }
                }

                // Folder Filter
                Section {
                    Toggle(isOn: $chatRepo.folderFilterEnabled) {
                        Label(L10n.string("Folder Filter"), systemImage: "folder")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                    .onChange(of: chatRepo.folderFilterEnabled) {
                        if chatRepo.folderFilterEnabled {
                            suppressedSelectedFolderRefreshId = chatRepo.selectedFolderId
                        } else {
                            suppressedSelectedFolderRefreshId = nil
                        }
                        Task {
                            await appState.refreshVisibleContent(includeFolders: chatRepo.folderFilterEnabled)
                        }
                    }
                    if chatRepository.folderFilterEnabled {
                        if chatRepository.folders.isEmpty {
                            if chatRepository.didAttemptFolderLoad {
                                Text(L10n.string("No folders"))
                                    .font(.caption)
                                    .foregroundStyle(WristTheme.Palette.secondaryText)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                                    .wristGlassRow()
                            } else {
                                LoadingListRow()
                                    .wristGlassRow()
                            }
                        } else {
                            Picker(selection: $chatRepo.selectedFolderId) {
                                ForEach(chatRepository.folders) { folder in
                                    Text(folder.title).tag(folder.id)
                                }
                            } label: {
                                Label(L10n.string("Folder"), systemImage: "tray")
                                    .font(.caption)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                            .wristGlassRow()
                            .onChange(of: chatRepo.selectedFolderId) {
                                if suppressedSelectedFolderRefreshId == chatRepo.selectedFolderId {
                                    suppressedSelectedFolderRefreshId = nil
                                    return
                                }
                                suppressedSelectedFolderRefreshId = nil
                                Task { await appState.refreshVisibleContent(includeFolders: false) }
                            }
                        }
                    }
                } header: {
                    Text(L10n.string("Chat Filter"))
                }

                // Language
                Section(L10n.string("Language")) {
                    Picker(selection: languageSelection) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.optionLabelKey))
                                .tag(language.rawValue)
                        }
                    } label: {
                        Label(L10n.string("Language"), systemImage: "globe")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }

                Section(L10n.string("Reactions")) {
                    Picker(selection: $quickReaction) {
                        ForEach(QuickReactionPreference.options, id: \.self) { emoji in
                            Text(emoji).tag(emoji)
                        }
                    } label: {
                        Label(L10n.string("Double-Tap Reaction"), systemImage: "hand.tap")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }

                // Storage
                Section(L10n.string("Storage")) {
                    HStack {
                        Text(L10n.string("Cache"))
                        Spacer()
                        Text(appState.cacheSizeMB)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                    }
                    .font(.caption)
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()

                    Button(role: .destructive) {
                        Task { await appState.clearCache() }
                    } label: {
                        HStack {
                            Text(L10n.string("Clear Cache"))
                            if appState.isClearingCache {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isClearingCache)
                    .font(.caption)
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }

                Section(L10n.string("Support")) {
                    Button {
                        openSupportChat()
                    } label: {
                        HStack {
                            Label(L10n.string("Report a Problem"), systemImage: "exclamationmark.bubble")
                                .font(.caption)
                            if supportResolving {
                                Spacer()
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .disabled(supportResolving)
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                    if let supportError {
                        Text(supportError)
                            .font(.caption2)
                            .foregroundStyle(WristTheme.Palette.warning)
                            .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                            .wristGlassRow()
                    }

                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label(L10n.string("Privacy Policy"), systemImage: "hand.raised")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()

                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        Label(L10n.string("Open-Source Licenses"), systemImage: "doc.plaintext")
                            .font(.caption)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }

                #if DEBUG
                TelemetryDebugSection(telemetry: appState.service.telemetry)
                #endif

                // Account
                Section(L10n.string("Account")) {
                    Button(L10n.string("Log Out"), role: .destructive) {
                        showLogoutConfirm = true
                    }
                    .font(.caption)
                    .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                    .wristGlassRow()
                }

                Section {
                    VStack(spacing: 2) {
                        Text(L10n.format("Orbitext v%@", AppConstants.App.version))
                            .font(.caption2)
                        Text(L10n.string("Unofficial Telegram client. Not affiliated with Telegram."))
                            .font(.caption2)
                            .foregroundStyle(WristTheme.Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
            }
            .wristListStyle()
            .navigationTitle(L10n.string("Settings"))
            .alert(L10n.string("Log Out?"), isPresented: $showLogoutConfirm) {
                Button(L10n.string("Log Out"), role: .destructive) {
                    Task { await appState.logout() }
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            }
            .task {
                appState.refreshCacheSize()
                await appState.notificationManager.checkStatus()
                notificationPermissionGranted = appState.notificationManager.isAuthorized
                quickReaction = QuickReactionPreference.sanitize(quickReaction)
                if chatRepository.folders.isEmpty && !chatRepository.didAttemptFolderLoad {
                    await appState.loadFoldersIfNeeded()
                }
                // Poll FLOOD_WAIT remaining time
                while !Task.isCancelled {
                    floodWaitRemaining = appState.floodWaitRemaining
                    guard floodWaitRemaining != nil else { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                floodWaitRemaining = appState.floodWaitRemaining
            }
    }

    private var connectionLabel: String {
        switch networkMonitor.connectionStatus {
        case .connected:
            return networkMonitor.connectionType.rawValue
        case .connecting:
            return L10n.string("Connecting...")
        case .offline:
            return L10n.string("Offline")
        }
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { appLanguage },
            set: { newValue in
                L10n.useLanguage(rawValue: newValue)
                appLanguage = newValue
            }
        )
    }

    private func openSupportChat() {
        guard !supportResolving else { return }
        supportResolving = true
        supportError = nil
        Task { @MainActor in
            defer { supportResolving = false }
            do {
                let chat = try await chatRepository.service.getChat(username: AppConstants.App.supportUsername)
                appState.router.openChat(chat)
            } catch {
                supportError = L10n.string("Couldn't open support chat. Check connection.")
            }
        }
    }

    private func formatFloodWait(_ seconds: Int) -> String {
        TimeFormatting.clockDuration(seconds)
    }
}
