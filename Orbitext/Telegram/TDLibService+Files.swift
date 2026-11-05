import Foundation
import os

// MARK: - File download, contacts, group info, drafts

extension TDLibService {
    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        let fileURL = try await localFileURL(fileId: fileId, priority: priority)
        // Memory-map the file so its full contents are not materialised
        // into RAM in one go. On watchOS the per-app memory budget is tight
        // and large media (multi-MB photos, videos, audio) used to spike
        // RSS by their entire size; mmap'd Data lets the kernel page bytes
        // in and out as the consumer reads them, bounding peak memory.
        // Falls back to a regular read if mmap is unavailable for this URL.
        let data: Data
        if let mapped = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            data = mapped
        } else {
            data = try Data(contentsOf: fileURL)
        }
        guard !data.isEmpty else { throw ServiceError.downloadFailed }
        return data
    }

    func localFileURL(fileId: String, priority: DownloadPriorityHandle) async throws -> URL {
        guard let fileIdInt = Int(fileId), fileIdInt > 0 else { throw ServiceError.invalidFileId }

        let known = await fileState(fileId: fileIdInt)
        if let url = known.flatMap(Self.completedLocalCopy) {
            return url
        }

        let download = FileDownload(fileId: fileIdInt, priority: priority)
        let observer = priority.addObserver { [weak self] newPriority in
            guard let self, download.move(to: newPriority) else { return }
            download.controls.submit { await self.moveDownload(download) }
        }
        defer {
            priority.removeObserver(observer)
            download.finish()
        }
        return try await withTaskCancellationHandler {
            try await downloadWithRetries(download, alreadyDownloaded: known?.local?.downloadedSize ?? 0)
        } onCancel: {
            stop(download)
        }
    }

    func downloadedFileURL(fileId: String) async -> URL? {
        guard let fileIdInt = Int(fileId), fileIdInt > 0 else { return nil }
        return await fileState(fileId: fileIdInt).flatMap(Self.completedLocalCopy)
    }

    /// TDLib downloads a file through a synchronous downloadFile, which
    /// answers once the file is complete, has failed or was cancelled. The
    /// request waits without a timeout for as long as the download makes
    /// progress; the caller ends it by cancelling.
    private func downloadWithRetries(_ download: FileDownload, alreadyDownloaded: Int64) async throws -> URL {
        let fileId = download.fileId
        for attempt in 1...3 {
            let result = try await downloadUnlessStalled(download, alreadyDownloaded: alreadyDownloaded)

            guard let local = result["local"] as? [String: Any],
                  let path = local["path"] as? String,
                  !path.isEmpty else {
                throw ServiceError.downloadFailed
            }

            let isCompleted = local["is_downloading_completed"] as? Bool ?? false
            let downloadedSize = toInt64(local["downloaded_size"])
            let expectedSize = max(toInt64(result["size"]), toInt64(result["expected_size"]))

            if isCompleted || (expectedSize > 0 && downloadedSize >= expectedSize) {
                let fileURL = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw ServiceError.downloadFailed
                }
                return fileURL
            }

            Logger.tdlib.debug("downloadFile incomplete for fileId=\(fileId), attempt \(attempt): downloaded=\(downloadedSize), expected=\(expectedSize)")

            if attempt < 3 {
                try await Task.sleep(for: downloadRetryDelay)
            }
        }

        throw ServiceError.downloadFailed
    }

    /// The synchronous downloadFile, raced against a watch on its progress:
    /// once nothing the transport downloads has gained bytes for
    /// `downloadStallTimeout`, the download is stopped and fails with
    /// `TDError.timeout`, as the request timeout used to fail it. A download
    /// that keeps gaining bytes, or waits behind others that do, is never cut
    /// off.
    private func downloadUnlessStalled(_ download: FileDownload, alreadyDownloaded: Int64) async throws -> [String: Any] {
        let response = try await withThrowingTaskGroup(of: TDResponse?.self) { group in
            group.addTask {
                let request: [String: Any] = [
                    "@type": "downloadFile",
                    "file_id": download.fileId,
                    "priority": download.priority.value.rawValue,
                    "offset": 0,
                    "limit": 0,
                    "synchronous": true
                ]
                let result = try await self.throttledSendWithoutTimeout(request) { request in
                    // A priority changed during the throttle wait goes out with the request.
                    request["priority"] = download.markSent().rawValue
                }
                return TDResponse(dict: result)
            }
            group.addTask {
                try await self.waitForStall(of: download, alreadyDownloaded: alreadyDownloaded)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let result = first else {
                Logger.tdlib.warning("downloadFile fileId=\(download.fileId) made no progress while nothing else downloaded either; stopping it")
                stop(download)
                throw TDError.timeout
            }
            // A file that arrived between two checks is progress as well.
            downloadProgress.noteProgress()
            return result
        }
        return response.dict
    }

    /// Returns once nothing the transport downloads has gained bytes for
    /// `downloadStallTimeout` since the request was sent.
    ///
    /// Time is counted in progress checks, not read from a clock: an app that
    /// was suspended wakes up to one overdue check, not to a stall that was
    /// only sleep. A check that gets no answer is skipped, and none is made
    /// while the client is paused, since it would wait out its request
    /// timeout for nothing.
    ///
    /// TDLib gives its download budget out strictly by priority, so a
    /// download queued behind others gains nothing until they finish. That is
    /// waiting, not stalling: a check counts as quiet only while no download
    /// of this transport gained bytes. getFile is offline, so watching costs
    /// no throttle slot.
    private func waitForStall(of download: FileDownload, alreadyDownloaded: Int64) async throws {
        let checksPerTimeout = downloadStallTimeout / downloadProgressInterval
        let quietChecksToStall = checksPerTimeout.isFinite ? max(1, Int(checksPerTimeout.rounded(.up))) : 1
        var lastSize = alreadyDownloaded
        var lastBeat = downloadProgress.count
        var quietChecks = 0
        while true {
            try await Task.sleep(for: downloadProgressInterval)
            // Before its request goes out the download waits in the throttle.
            guard download.isSent, getTD()?.isPaused != true, let size = await fileState(fileId: download.fileId)?.local?.downloadedSize else { continue }
            if size != lastSize {
                lastSize = size
                downloadProgress.noteProgress()
            }
            let beat = downloadProgress.count
            if beat != lastBeat {
                lastBeat = beat
                quietChecks = 0
                continue
            }
            quietChecks += 1
            if quietChecks >= quietChecksToStall { return }
        }
    }

    /// Moves a download TDLib is already running. A downloadFile with the
    /// same offset and limit changes its priority and leaves the waiting
    /// synchronous request in place; it is offline work for TDLib, so it
    /// takes no throttle slot.
    ///
    /// TDLib keeps the priority of the last request it reads, so the requests
    /// about one download go out one at a time, in the order they were made
    /// (`FileDownload.controls`). Each tells TDLib the priority wanted when
    /// its turn comes, and nothing when TDLib has it or the download ended.
    private func moveDownload(_ download: FileDownload) async {
        guard let priority = download.takePriorityToTell() else { return }
        _ = try? await localSend([
            "@type": "downloadFile",
            "file_id": download.fileId,
            "priority": priority.rawValue,
            "offset": 0,
            "limit": 0,
            "synchronous": false
        ])
    }

    /// Ends a download nobody waits for and, if TDLib may be running it,
    /// stops it behind the moves already made. TDLib keeps what it has, so
    /// asking for the file again resumes it.
    private func stop(_ download: FileDownload) {
        guard download.finish() else { return }
        download.controls.submit {
            _ = try? await self.localSend([
                "@type": "cancelDownloadFile",
                "file_id": download.fileId,
                "only_if_pending": false
            ])
        }
    }

    /// What TDLib knows about a file, from the offline getFile; nil when the
    /// request fails.
    private func fileState(fileId: Int) async -> TDApi.File? {
        guard let result = try? await localSend(["@type": "getFile", "file_id": fileId]) else { return nil }
        return TDApi.decodeFile(result)
    }

    /// The file when TDLib already holds all of it, so it needs no throttle
    /// slot and is served during a FLOOD_WAIT on downloadFile as well. A copy
    /// TDLib lists but that is gone from disk is left to downloadFile, which
    /// checks the location and downloads it again.
    private static func completedLocalCopy(_ file: TDApi.File) -> URL? {
        guard let local = file.local, local.isDownloadingCompleted, !local.path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: local.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func getContact(userId: Int64) async throws -> ContactInfo {
        return try await ContactInfo(user: cachedOrFetchUser(userId: userId))
    }

    func getContacts() async throws -> [ContactInfo] {
        let result = try await throttledSend(["@type": "getContacts"])

        guard let userIds = result["user_ids"] as? [Any] else {
            return []
        }

        return try await fetchContactInfos(userIds: userIds)
    }

    func searchContacts(query: String) async throws -> [ContactInfo] {
        let result = try await throttledSend([
            "@type": "searchContacts",
            "query": query,
            "limit": AppConstants.Message.searchLimit
        ])

        guard let userIds = result["user_ids"] as? [Any] else {
            return []
        }

        return try await fetchContactInfos(userIds: userIds)
    }

    private func fetchContactInfos(userIds: [Any]) async throws -> [ContactInfo] {
        // getUser reads from TDLib's local cache - no network, no throttle needed.
        // Bypassing throttle turns 100 contacts from ~5s to ~0.1s.
        var seenUserIds = Set<Int64>()
        let uniqueUserIds = userIds.compactMap { rawId -> Int64? in
            let userId = toInt64(rawId)
            guard userId > 0, !seenUserIds.contains(userId) else { return nil }
            seenUserIds.insert(userId)
            return userId
        }
        var contacts: [ContactInfo] = []
        contacts.reserveCapacity(uniqueUserIds.count)
        for userId in uniqueUserIds {
            // Try userCache first (already in memory)
            if let cached = userCache.get(userId) {
                contacts.append(ContactInfo(user: cached))
                continue
            }
            try await contacts.append(ContactInfo(user: cachedOrFetchUser(userId: userId)))
        }
        return contacts
    }

    func getMe() async throws -> ContactInfo {
        let result = try await throttledSend(["@type": "getMe"])
        return parseContactInfo(result)
    }

    func getGroupInfo(chatId: Int64) async throws -> GroupInfo {
        let chat = try await dedupedLocalSend(
            ["@type": "getChat", "chat_id": chatId],
            key: "getChat:\(chatId)"
        )
        guard let chatType = chat["type"] as? [String: Any],
              let typeStr = chatType["@type"] as? String else {
            return GroupInfo()
        }
        var info = GroupInfo()
        if typeStr == "chatTypeSupergroup" {
            let sgId = toInt64(chatType["supergroup_id"])
            let sgFull = try await throttledSend(["@type": "getSupergroupFullInfo", "supergroup_id": sgId])
            info.memberCount = sgFull["member_count"] as? Int
            info.description = sgFull["description"] as? String
        } else if typeStr == "chatTypeBasicGroup" {
            let bgId = toInt64(chatType["basic_group_id"])
            let bgFull = try await throttledSend(["@type": "getBasicGroupFullInfo", "basic_group_id": bgId])
            info.memberCount = (bgFull["members"] as? [Any])?.count
            info.description = bgFull["description"] as? String
        }
        return info
    }

    func setDraft(chatId: Int64, text: String?) async throws {
        var draftMessage: Any = NSNull()
        if let text, !text.isEmpty {
            draftMessage = [
                "@type": "draftMessage",
                "input_message_text": [
                    "@type": "inputMessageText",
                    "text": [
                        "@type": "formattedText",
                        "text": text
                    ]
                ]
            ] as [String: Any]
        }

        _ = try await throttledSend([
            "@type": "setChatDraftMessage",
            "chat_id": chatId,
            "draft_message": draftMessage
        ])
    }

    func getDraft(chatId: Int64) async throws -> String? {
        let result = try await throttledSend([
            "@type": "getChat",
            "chat_id": chatId
        ])
        return extractDraftText(from: result)
    }
}

/// One download in flight: its caller's priority and what TDLib was told.
final class FileDownload: @unchecked Sendable {
    let fileId: Int
    let priority: DownloadPriorityHandle
    /// The requests about this download that follow its own, in order.
    let controls = OrderedJobs()
    private let lock = NSLock()
    /// The priority wanted since the request went out.
    private var sent: DownloadPriority?
    /// The priority of the latest request that reached TDLib.
    private var told: DownloadPriority?
    private var isFinished = false

    init(fileId: Int, priority: DownloadPriorityHandle) {
        self.fileId = fileId
        self.priority = priority
    }

    /// Records that the request goes out now, at the caller's current
    /// priority, and returns that priority.
    func markSent() -> DownloadPriority {
        lock.withLock {
            let current = priority.value
            sent = current
            told = current
            return current
        }
    }

    /// Whether a request has gone out; false while it waits in the throttle.
    var isSent: Bool {
        lock.withLock { sent != nil }
    }

    /// Whether the running download has to move to `newPriority`. It does not
    /// before its request went out (the request carries the new priority),
    /// after it ended, or when that priority is wanted already.
    func move(to newPriority: DownloadPriority) -> Bool {
        lock.withLock {
            guard !isFinished, let sent, sent != newPriority else { return false }
            self.sent = newPriority
            return true
        }
    }

    /// The priority a move has to tell TDLib now; nil when TDLib has the one
    /// wanted, or the download ended.
    func takePriorityToTell() -> DownloadPriority? {
        lock.withLock {
            guard !isFinished, let sent, sent != told else { return nil }
            told = sent
            return sent
        }
    }

    /// Ends the bookkeeping. Returns true the first time if a request went
    /// out, which is when TDLib may still be downloading.
    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return sent != nil
        }
    }
}

/// Runs jobs one after another, in the order they were submitted, each when
/// the one before it is done.
final class OrderedJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    /// Returns at once; submissions from one thread run in that order.
    func submit(_ job: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = last
            last = Task {
                await previous?.value
                await job()
            }
        }
    }
}

/// A counter that moves whenever a download of the transport gains bytes or
/// completes. A watch that sees it move knows TDLib is working, even when its
/// own download has nothing yet.
final class DownloadProgressBeat: @unchecked Sendable {
    private let lock = NSLock()
    private var beats = 0

    var count: Int {
        lock.withLock { beats }
    }

    func noteProgress() {
        lock.withLock { beats += 1 }
    }
}
