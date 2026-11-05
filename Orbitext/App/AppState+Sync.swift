import Foundation
import os

#if DEBUG
@inline(__always)
fileprivate func logDebug(_ message: String) {
    Logger.app.debug("\(message)")
}
#else
@inline(__always)
fileprivate func logDebug(_ message: String) {}
#endif

// MARK: - Sync Pipeline

extension AppState {
    struct SyncRequest {
        var loadChats = false
        var loadFolders = false
        var flushMessageQueue = false
        var requiresReadyConnection = false
        var reasons: Set<String> = []

        var isEmpty: Bool {
            !loadChats && !loadFolders && !flushMessageQueue
        }

        mutating func merge(_ other: Self) {
            loadChats = loadChats || other.loadChats
            loadFolders = loadFolders || other.loadFolders
            flushMessageQueue = flushMessageQueue || other.flushMessageQueue
            requiresReadyConnection = requiresReadyConnection || other.requiresReadyConnection
            reasons.formUnion(other.reasons)
        }

        var debugSummary: String {
            "reasons=[\(reasons.sorted().joined(separator: ","))] chats=\(loadChats) folders=\(loadFolders) flushQueue=\(flushMessageQueue) requiresReady=\(requiresReadyConnection)"
        }
    }

    enum SyncRequestFactory {
        static func visibleContent(needsChats: Bool, needsFolders: Bool) -> SyncRequest {
            SyncRequest(
                loadChats: needsChats,
                loadFolders: needsFolders,
                flushMessageQueue: true,
                requiresReadyConnection: true,
                reasons: ["visible_content"]
            )
        }

        static func visibleContentRetry() -> SyncRequest {
            SyncRequest(
                loadChats: true,
                loadFolders: false,
                flushMessageQueue: false,
                requiresReadyConnection: true,
                reasons: ["visible_content_retry"]
            )
        }

        static func visibleRefresh(includeFolders: Bool, flushMessageQueue: Bool) -> SyncRequest {
            SyncRequest(
                loadChats: true,
                loadFolders: includeFolders,
                flushMessageQueue: flushMessageQueue,
                requiresReadyConnection: true,
                reasons: ["visible_refresh"]
            )
        }

        static func folderPrefetch() -> SyncRequest {
            SyncRequest(
                loadChats: false,
                loadFolders: true,
                flushMessageQueue: false,
                requiresReadyConnection: true,
                reasons: ["folder_prefetch"]
            )
        }

        static func becameActive(shouldReloadChats: Bool) -> SyncRequest {
            SyncRequest(
                loadChats: shouldReloadChats,
                loadFolders: false,
                flushMessageQueue: true,
                requiresReadyConnection: true,
                reasons: ["became_active"]
            )
        }

        static func backgroundRefresh(shouldLoadFolders: Bool) -> SyncRequest {
            SyncRequest(
                loadChats: true,
                loadFolders: shouldLoadFolders,
                flushMessageQueue: false,
                requiresReadyConnection: false,
                reasons: ["background_refresh"]
            )
        }

        static func remotePush() -> SyncRequest {
            SyncRequest(
                loadChats: true,
                loadFolders: false,
                flushMessageQueue: false,
                requiresReadyConnection: false,
                reasons: ["remote_push"]
            )
        }
    }

    func ensureVisibleContentLoaded() async {
        guard !Task.isCancelled else { return }
        // Recover from the "chats array got cleared but isInitialSyncComplete
        // stayed true" pathology - if it ever happens, ChatListView's .task
        // would have stranded the user on an empty list because loadChats
        // was gated solely on !isInitialSyncComplete. Now we also retry
        // when chats is unexpectedly empty.
        let needsChats = !chatRepository.isInitialSyncComplete || chatRepository.chats.isEmpty
        let request = SyncRequestFactory.visibleContent(
            needsChats: needsChats,
            needsFolders: shouldLoadFoldersForVisibleContent
        )
        let authDescription = String(describing: authManager.authState)
        let tdlibState = networkMonitor.tdlibState.rawValue
        let chatCount = chatRepository.chats.count
        let initialSyncComplete = chatRepository.isInitialSyncComplete
        logDebug(
            "ensureVisibleContentLoaded requested; auth=\(authDescription) tdlib=\(tdlibState) chats=\(chatCount) initialSync=\(initialSyncComplete) request=\(request.debugSummary)"
        )
        enqueueSync(request)

        guard request.loadChats || request.loadFolders || request.flushMessageQueue else { return }
        if request.loadChats {
            let deadline = ContinuousClock.now + .seconds(180)
            var retryCount = 0
            let maxRetries = 3
            while !Task.isCancelled && authManager.authState == .ready && !chatRepository.isInitialSyncComplete {
                guard ContinuousClock.now < deadline else {
                    Logger.app.warning("ensureVisibleContentLoaded timed out after 180s")
                    break
                }
                if syncTask != nil {
                    guard await waitForSyncPipelineToDrain(until: deadline) == .drained else { break }
                    if !chatRepository.isInitialSyncComplete && syncTask == nil && pendingSyncRequest.isEmpty {
                        retryCount += 1
                        if retryCount > maxRetries {
                            Logger.app.warning("ensureVisibleContentLoaded giving up after \(maxRetries) retries")
                            break
                        }
                        let backoff = min(retryCount * 5, 15)
                        logDebug("ensureVisibleContentLoaded retry \(retryCount)/\(maxRetries) in \(backoff)s")
                        do { try await Task.sleep(for: .seconds(backoff)) } catch { return }
                        enqueueSync(SyncRequestFactory.visibleContentRetry())
                    }
                } else if pendingSyncRequest.isEmpty {
                    retryCount += 1
                    if retryCount > maxRetries {
                        Logger.app.warning("ensureVisibleContentLoaded giving up: no pending sync after \(maxRetries) retries")
                        break
                    }
                    let backoff = min(retryCount * 5, 15)
                    logDebug("ensureVisibleContentLoaded no pending sync, retry \(retryCount)/\(maxRetries) in \(backoff)s")
                    do { try await Task.sleep(for: .seconds(backoff)) } catch { return }
                    enqueueSync(SyncRequestFactory.visibleContentRetry())
                } else {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            let finishedChatCount = chatRepository.chats.count
            let finishedInitialSync = chatRepository.isInitialSyncComplete
            logDebug(
                "ensureVisibleContentLoaded finished; chats=\(finishedChatCount) initialSync=\(finishedInitialSync) retries=\(retryCount)"
            )
            return
        }

        await waitForSyncPipelineToDrain()
    }

    func refreshVisibleContent(includeFolders: Bool, flushMessageQueue: Bool = false) async {
        enqueueSync(
            SyncRequestFactory.visibleRefresh(
                includeFolders: includeFolders && shouldLoadFoldersForVisibleContent,
                flushMessageQueue: flushMessageQueue
            )
        )
        await waitForSyncPipelineToDrain()
    }

    func loadFoldersIfNeeded() async {
        guard chatRepository.folders.isEmpty, !chatRepository.didAttemptFolderLoad else { return }
        enqueueSync(SyncRequestFactory.folderPrefetch())
        await waitForSyncPipelineToDrain()
    }

    func enqueueSync(_ request: SyncRequest) {
        guard !request.isEmpty else { return }
        logDebug("enqueueSync incoming \(request.debugSummary)")
        pendingSyncRequest.merge(request)
        let pendingSummary = pendingSyncRequest.debugSummary
        logDebug("enqueueSync merged pending \(pendingSummary)")
        tryStartPendingSyncIfPossible()
    }

    func tryStartPendingSyncIfPossible() {
        guard !pendingSyncRequest.isEmpty else { return }
        guard syncTask == nil else {
            let pendingSummary = pendingSyncRequest.debugSummary
            logDebug("Sync start deferred: task already running; pending=\(pendingSummary)")
            return
        }
        guard authManager.authState == .ready else {
            let authDescription = String(describing: authManager.authState)
            let pendingSummary = pendingSyncRequest.debugSummary
            logDebug("Sync start deferred: auth not ready (\(authDescription)); pending=\(pendingSummary)")
            return
        }
        guard !pendingSyncRequest.requiresReadyConnection || networkMonitor.tdlibState.canServeRequests else {
            let tdlibState = networkMonitor.tdlibState.rawValue
            let pendingSummary = pendingSyncRequest.debugSummary
            logDebug("Sync start deferred: TDLib not ready (\(tdlibState)); pending=\(pendingSummary)")
            return
        }

        let request = pendingSyncRequest
        pendingSyncRequest = SyncRequest()
        let tdlibState = networkMonitor.tdlibState.rawValue
        Logger.app.info("Sync STARTING: \(request.debugSummary, privacy: .public) tdlib=\(tdlibState, privacy: .public)")
        syncGeneration &+= 1
        let generation = syncGeneration
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeSyncRequest(request)
            // Reset may have cancelled this request and installed a new task
            // while a service operation was suspended or ignored cancellation.
            guard self.syncGeneration == generation else { return }
            self.syncTask = nil
            logDebug("Sync task completed, checking for pending...")
            self.tryStartPendingSyncIfPossible()
        }
    }

    func executeSyncRequest(_ request: SyncRequest) async {
        let syncStart = ContinuousClock.now
        logDebug("Executing sync \(request.debugSummary)")

        guard !Task.isCancelled else { return }
        if request.loadFolders {
            logDebug("sync step: loadFolders START")
            await chatRepository.loadFolders()
            logDebug("sync step: loadFolders DONE (\(ContinuousClock.now - syncStart))")
        }
        guard !Task.isCancelled else { return }
        if request.loadChats {
            logDebug("sync step: loadChats START")
            await chatRepository.loadChats()
            logDebug("sync step: loadChats DONE (\(ContinuousClock.now - syncStart))")
        }
        guard !Task.isCancelled else { return }
        if request.flushMessageQueue {
            logDebug("sync step: flushMessageQueue START")
            await messageManager.flushMessageQueue()
            logDebug("sync step: flushMessageQueue DONE (\(ContinuousClock.now - syncStart))")
        }
        let chatCount = chatRepository.chats.count
        let folderCount = chatRepository.folders.count
        let initialSyncComplete = chatRepository.isInitialSyncComplete
        let totalElapsed = ContinuousClock.now - syncStart
        logDebug(
            "Finished sync \(request.debugSummary); chats=\(chatCount) folders=\(folderCount) initialSync=\(initialSyncComplete) elapsed=\(totalElapsed)"
        )
    }

    enum SyncDrainResult: Equatable {
        case drained
        case timedOut
        case cancelled
    }

    @discardableResult
    func waitForSyncPipelineToDrain(timeout: TimeInterval? = nil) async -> SyncDrainResult {
        let deadline = timeout.map { ContinuousClock.now + .seconds(max(0, $0)) }
        return await waitForSyncPipelineToDrain(until: deadline)
    }

    private func waitForSyncPipelineToDrain(until deadline: ContinuousClock.Instant?) async -> SyncDrainResult {
        let clock = ContinuousClock()
        while syncTask != nil || !pendingSyncRequest.isEmpty {
            guard !Task.isCancelled else { return .cancelled }
            if let deadline, clock.now >= deadline {
                let pendingSummary = pendingSyncRequest.debugSummary
                let syncRunning = syncTask != nil
                Logger.app.warning("waitForSyncPipelineToDrain timed out; pending=\(pendingSummary, privacy: .public) syncRunning=\(syncRunning)")
                return .timedOut
            }
            // Do not await the shared task's value: cancellation of its waiter
            // cannot interrupt that await. A bounded sleep observes completion,
            // our own cancellation and the monotonic deadline independently.
            // Timing out a waiter must not cancel work used by another caller.
            let nextCheck = clock.now + .milliseconds(50)
            do {
                try await clock.sleep(until: deadline.map { min($0, nextCheck) } ?? nextCheck)
            } catch {
                return .cancelled
            }
        }
        return Task.isCancelled ? .cancelled : .drained
    }

    func resetSyncPipeline() {
        if syncTask != nil || !pendingSyncRequest.isEmpty {
            let pendingSummary = pendingSyncRequest.debugSummary
            let syncRunning = syncTask != nil
            logDebug("Resetting sync pipeline; pending=\(pendingSummary) syncRunning=\(syncRunning)")
        }
        syncGeneration &+= 1
        pendingSyncRequest = SyncRequest()
        syncTask?.cancel()
        syncTask = nil
    }

    private var shouldLoadFoldersForVisibleContent: Bool {
        chatRepository.folderFilterEnabled
            && chatRepository.folders.isEmpty
            && !chatRepository.didAttemptFolderLoad
    }
}
