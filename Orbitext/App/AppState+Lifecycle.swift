import Foundation
import os
import WatchKit

// MARK: - Lifecycle & Background Refresh

extension AppState {
    func handleBecameActive() {
        lifecycle.sceneDidBecomeActive()
        imageCache.restoreDecodedByteLimit()
        // The first activation of a launch starts the client; a later one
        // finds it started.
        if !lifecycle.state.isStarted {
            Task { await initialize() }
        }
        guard authManager.authState == .ready else { return }

        // Debounce: watchOS can fire scenePhase .active multiple times in quick succession
        let now = ContinuousClock.now
        guard now - lastBecameActiveTime > .seconds(2) else {
            Logger.app.debug("handleBecameActive debounced (fired <2s ago)")
            return
        }
        lastBecameActiveTime = now

        let request = SyncRequestFactory.becameActive(shouldReloadChats: chatRepository.isInitialSyncComplete)
        Logger.app.info("Foreground sync requested: \(request.debugSummary, privacy: .public)")
        enqueueSync(request)
    }

    func handleEnteredBackground() {
        lifecycle.sceneDidEnterBackground()
        // A suspended app with a smaller footprint is a later choice for
        // jetsam. The histories of the chats not open and all but the latest
        // pictures go; they load again from TDLib when needed. The limit
        // holds until the scene is active again, so the loads still running
        // do not fill the cache before the app is suspended.
        chatMessageStore.clearInactiveChats()
        imageCache.limitDecodedBytes(to: AppConstants.Cache.backgroundDecodedImageBytes)
        // Flush coalesced disk writes BEFORE handing control back to the
        // system. ListCache's 0.5s debounce can otherwise drop the latest
        // chat / contact snapshot if watchOS suspends us before the
        // deferred DispatchWorkItem fires.
        flushCoalescedDiskWrites()
        BackgroundRefreshScheduler.scheduleNext()
    }

    /// The system runs short of memory (`MemoryPressureMonitor`): let go of
    /// what is cheap to make again. The cached pictures decode again from
    /// TDLib's files, and the histories of the chats not open load again when
    /// opened. The open chat keeps its history.
    func handleMemoryPressure() {
        Logger.app.warning("Memory pressure: letting the cached pictures and the histories of closed chats go")
        imageCache.trim(toDecodedBytes: 0)
        chatMessageStore.clearInactiveChats()
    }

    /// Synchronously force-write any pending coalesced ListCache snapshots
    /// so a subsequent suspension does not lose them. Safe to call multiple
    /// times - flush() is a no-op when nothing is pending.
    func flushCoalescedDiskWrites() {
        chatRepository.flushChatListCaches()
        messageManager.contactListCache.flush()
    }

    func performBackgroundRefresh() async {
        defer { BackgroundRefreshScheduler.scheduleNext() }
        Logger.app.info("Background refresh STARTED")

        let outcome = await lifecycle.withLease(.backgroundRefresh, policy: .backgroundRefresh) {
            let request = SyncRequestFactory.backgroundRefresh(
                shouldLoadFolders: chatRepository.folderFilterEnabled && chatRepository.folders.isEmpty
            )
            Logger.app.info("Background refresh sync requested: \(request.debugSummary, privacy: .public)")
            enqueueSync(request)
            guard await waitForSyncPipelineToDrain(timeout: 8) == .drained else { return }

            widgetSync.update(chats: chatRepository.filteredChats, isInBackground: chatRepository.isInBackgroundState)
            Logger.app.info("Background refresh COMPLETED")
        }
        if case .skipped(let reason) = outcome {
            Logger.app.debug("Background refresh skipped: \(String(describing: reason), privacy: .public)")
        }
    }
}
