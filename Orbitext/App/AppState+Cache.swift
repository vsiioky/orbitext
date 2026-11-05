import Foundation
import os

// MARK: - Cache Management & Account

extension AppState {
    func logout() async {
        guard lifecycle.beginTransition(.loggingOut) else {
            Logger.app.warning("Logout ignored: a session change is already running")
            return
        }
        defer { lifecycle.endTransition(.loggingOut) }
        Logger.app.info("Logout requested")
        resetSyncPipeline()
        messageManager.cancelQueueFlush()
        router.popToRoot()
        authManager.authState = .closing
        authManager.clearQRCodeLinkAndThrottle()
        errorPresenter.dismiss()

        // Cleared by clearLocalSessionData; survives a failure or a kill.
        preferences.setLogoutCleanupPending(true)
        do {
            // Signs out on the server within a bounded wait, then wipes locally.
            // Session data is disposable only after native TDLib has
            // confirmed shutdown; a close timeout must preserve it.
            try await service.logout()
        } catch {
            authManager.authState = .error(error.localizedDescription)
            errorPresenter.show(error)
            Logger.app.error("Logout failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        lifecycle.retireCurrentClient()
        clearLocalSessionData()
        authManager.authState = .waitPhoneNumber
    }

    /// Used after every successful destructive auth restart, including retry
    /// after a failed logout. Preserved account data must not survive that retry.
    func clearLocalSessionData() {
        router.popToRoot()
        // The notification mark survives resetAll and would keep muting that
        // chat for the next account.
        chatSession.endAll()
        chatMessageStore.resetAll()
        botKeyboardStore.resetAll()
        sponsoredMessageStore.resetAll()
        chatRepository.resetLoadedState()
        chatRepository.folderFilterEnabled = false
        chatRepository.selectedFolderId = 0
        chatRepository.draftStore.clearAll()
        messageManager.messageQueue.clear()
        messageManager.clearCache()
        imageCache.clear()
        voiceManager.cleanup()
        preferences.clearSessionPreferences()
        widgetSync.update(chats: [], isInBackground: chatRepository.isInBackgroundState)
        preferences.setLogoutCleanupPending(false)
    }

    /// TDLib resumes a logout that reached its binlog on the next launch and
    /// wipes its own database, but not the app's caches, drafts and queue.
    func finishInterruptedLogoutIfNeeded() {
        guard preferences.isLogoutCleanupPending else { return }
        Logger.app.warning("Finishing an interrupted logout: clearing app-owned session data")
        clearLocalSessionData()
    }

    /// What Settings counts as the cache: what Clear cache frees. TDLib's
    /// database is not part of it, or the number would not come near zero
    /// after a clear.
    func refreshCacheSize() {
        cacheRefreshGeneration &+= 1
        let generation = cacheRefreshGeneration
        let transportDirectories = service.cacheDirectories
        let voiceDir = VoiceManager.recordingsDir
        let scan = scanCacheSize
        Task.detached {
            let total = scan(transportDirectories, voiceDir)
            let formatted = String(format: "%.1f MB", Double(total) / 1_048_576)
            await MainActor.run { [weak self] in
                guard let self, cacheRefreshGeneration == generation else { return }
                cacheSizeMB = formatted
            }
        }
    }

    nonisolated static func scanCacheSize(transportDirectories: [URL], recordingsDirectory: URL) -> Int64 {
        cacheDirectories(transportDirectories: transportDirectories, recordingsDirectory: recordingsDirectory)
            .reduce(Int64(0)) { $0 + directorySize($1) }
    }

    /// Looking up the app group container can create it, so not on the main actor.
    nonisolated static func cacheDirectories(transportDirectories: [URL], recordingsDirectory: URL) -> [URL] {
        transportDirectories + [recordingsDirectory] + [SharedPlaybackFiles.appGroupDirectory()].compactMap(\.self)
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Clear cache in Settings: the app's own copies first, then the media
    /// the transport downloaded. The size is read once both are gone. A tap
    /// while a run is going does nothing: a second optimizeStorage makes
    /// TDLib abort the first and scan again.
    func clearCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        imageCache.clear()
        voiceManager.cleanup()
        do {
            try await service.clearFileCache()
        } catch {
            Logger.app.warning("Clear cache: the transport kept its files: \(error.localizedDescription, privacy: .public)")
        }
        refreshCacheSize()
    }

    /// Returns remaining FLOOD_WAIT seconds, or nil if no active flood wait.
    var floodWaitRemaining: Int? {
        service.currentFloodWaitRemaining()
    }
}
