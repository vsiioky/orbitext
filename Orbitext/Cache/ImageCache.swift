import Foundation
import ImageIO
import os
import SwiftUI

/// The one owner of media loads: an in-memory LRU of decoded images over the
/// files TDLib keeps. Avoids repeated decoding of frequently shown images and
/// shares one transport request per file among the views waiting for it.
///
/// There is no disk layer of its own. TDLib stores what it downloaded and
/// serves a complete file without a throttle slot, and its file ids number
/// the files of one TDLib instance, so bytes kept under an id across a
/// relaunch would belong to another file.
@MainActor
@Observable
final class ImageCache {
    typealias ThumbnailDecoder = @Sendable (Data, Int) async -> UIImage?

    /// Doubly-linked recency-list node. Stored only inside `cache` (the
    /// hash map) and threaded together by head/tail pointers, so touch,
    /// insert, and evict are all O(1) - replacing the previous array-based
    /// accessOrder which paid O(n) on every cache touch.
    private struct ImageKey: Hashable {
        let fileId: String
        let maxDimension: Int
    }

    private final class Node {
        let key: ImageKey
        var entry: CacheEntry
        weak var prev: Node?
        var next: Node?
        init(key: ImageKey, entry: CacheEntry) {
            self.key = key
            self.entry = entry
        }
    }

    private var cache: [ImageKey: Node] = [:]
    private var imageKeysByFile: [String: Set<ImageKey>] = [:]
    private var decodedByteCount = 0
    /// What the decoded bitmaps may take now: `maxDecodedBytes`, or less while
    /// the app is away (`limitDecodedBytes`).
    private var decodedByteLimit = ImageCache.maxDecodedBytes
    // head = least recently used, tail = most recently used.
    private var head: Node?
    private var tail: Node?
    /// Remains registered until every caller has finished publishing its result,
    /// including callers resuming after the shared download task has completed.
    ///
    /// Its readers decide the download: it runs at the highest priority among
    /// them, and stops when the last one is gone.
    private final class FileOperation {
        private struct Reader {
            var priority: DownloadPriority
            var loads: Int
        }

        var isValid = true
        /// Shared with the transport while it downloads the file.
        let priority: DownloadPriorityHandle
        var download: Task<Data?, Never>?
        var localFile: Task<TransportFile?, Never>?
        var decodes: [Int: Task<UIImage?, Never>] = [:]
        private var readers: [UUID: Reader] = [:]

        init(priority: DownloadPriority) {
            self.priority = DownloadPriorityHandle(priority)
        }

        var hasReaders: Bool {
            !readers.isEmpty
        }

        var readerCount: Int {
            readers.count
        }

        func join(_ requester: UUID, priority: DownloadPriority) {
            var reader = readers[requester] ?? Reader(priority: priority, loads: 0)
            reader.priority = priority
            reader.loads += 1
            readers[requester] = reader
            updatePriority()
        }

        func leave(_ requester: UUID) {
            guard var reader = readers[requester] else { return }
            reader.loads -= 1
            readers[requester] = reader.loads > 0 ? reader : nil
            updatePriority()
        }

        func setPriority(_ priority: DownloadPriority, for requester: UUID) {
            guard readers[requester] != nil else { return }
            readers[requester]?.priority = priority
            updatePriority()
        }

        /// Nobody waits for the file any more.
        func stopTransfers() {
            download?.cancel()
            localFile?.cancel()
        }

        func invalidate() {
            isValid = false
            stopTransfers()
            for decode in decodes.values { decode.cancel() }
            decodes.removeAll()
        }

        private func updatePriority() {
            guard let highest = readers.values.map(\.priority).max() else { return }
            priority.update(highest)
        }
    }
    private var fileOperations: [String: FileOperation] = [:]
    /// Files of self-destructing media (Telegram API Terms of Service 1.4).
    /// Their bitmaps are never stored, so nothing of them outlives the viewer
    /// that drew them.
    private var uncachedFileIds: Set<String> = []
    private static let maxEntries = 50
    private static let maxDecodedBytes = 12 * 1024 * 1024

    struct CacheEntry {
        let image: UIImage
        let data: Data

        var decodedBytes: Int {
            guard let bitmap = image.cgImage else { return 0 }
            return bitmap.bytesPerRow * bitmap.height
        }
    }

    private let playbackFiles: SharedPlaybackFiles
    private let files: any TelegramFileAccess
    private let thumbnailDecoder: ThumbnailDecoder

    init(
        service: any TelegramFileAccess,
        playbackFiles: SharedPlaybackFiles = SharedPlaybackFiles(),
        thumbnailDecoder: @escaping ThumbnailDecoder = { data, maxDimension in
            ImageCache.decodeThumbnail(data, maxDimension: maxDimension)
        }
    ) {
        self.playbackFiles = playbackFiles
        self.files = service
        self.thumbnailDecoder = thumbnailDecoder
    }

    /// Maximum pixel dimension for in-memory images on watch.
    /// Images larger than this are downsampled to save RAM.
    private static let maxImageDimension = AppConstants.UI.Thumbnail.pixelWidth

    /// Load thumbnail image by fileId - downsampled for list/preview display.
    /// Images are downsampled to watch-appropriate sizes to reduce memory.
    ///
    /// A view that waits for the file can pass the same `requester` to
    /// `setPriority` to move the download, as when the user asks for it.
    /// Cancelling the calling task ends the wait.
    func load(fileId: String, priority: DownloadPriority = .onScreen, requester: UUID = UUID()) async -> UIImage? {
        await loadThumbnail(fileId: fileId, maxDimension: Self.maxImageDimension, priority: priority, requester: requester)
    }

    /// Cache each requested pixel size independently so avatars stay small
    /// without repeatedly decoding when their rows reenter the viewport.
    func load(
        fileId: String,
        maxDimension: CGFloat,
        priority: DownloadPriority = .onScreen,
        requester: UUID = UUID()
    ) async -> UIImage? {
        guard maxDimension.isFinite, maxDimension > 0 else { return nil }
        // The full-screen viewer uses loadFullSize. Thumbnail requests never
        // need an unbounded allocation even if given a malformed dimension.
        let pixels = Int(min(maxDimension.rounded(.up), 4096))
        return await loadThumbnail(fileId: fileId, maxDimension: pixels, priority: priority, requester: requester)
    }

    /// Moves the download a reader waits for: the file downloads at the
    /// highest priority among its readers. Does nothing once `requester` no
    /// longer waits for `fileId`.
    func setPriority(_ priority: DownloadPriority, fileId: String, requester: UUID) {
        fileOperations[fileId]?.setPriority(priority, for: requester)
    }

    /// How many views wait for `fileId` right now. Tests wait on it to know a
    /// reader has joined, instead of yielding and hoping.
    func readerCount(fileId: String) -> Int {
        fileOperations[fileId]?.readerCount ?? 0
    }

    private func loadThumbnail(fileId: String, maxDimension: Int, priority: DownloadPriority, requester: UUID) async -> UIImage? {
        let key = ImageKey(fileId: fileId, maxDimension: maxDimension)
        return await withFileOperation(fileId: fileId, priority: priority, requester: requester) { operation in
            if let node = cache[key] {
                moveToTail(node)
                return node.entry.image
            }
            guard let data = await fetchData(fileId: fileId, operation: operation),
                  operation.isValid, !Task.isCancelled else { return nil }
            // Another caller may have finished while the download was awaited.
            if let node = cache[key] {
                moveToTail(node)
                return node.entry.image
            }

            let decode: Task<UIImage?, Never>
            if let existing = operation.decodes[maxDimension] {
                decode = existing
            } else {
                let decoder = thumbnailDecoder
                decode = Task.detached(priority: .utility) {
                    guard !Task.isCancelled else { return nil }
                    let image = await decoder(data, maxDimension)
                    return Task.isCancelled ? nil : image
                }
                operation.decodes[maxDimension] = decode
            }
            guard let image = await decode.value,
                  operation.isValid, !Task.isCancelled else { return nil }
            store(key: key, image: image, data: data)
            return image
        }
    }

    /// Load the photo for the full-screen viewer, decoded to at most
    /// `AppConstants.UI.Viewer.maxPixelSize` on its long side; a smaller photo
    /// keeps its pixels.
    ///
    /// The bitmap is made here, off the main actor. A UIImage over the file's
    /// bytes is decoded when it is first drawn, on the main thread in the
    /// middle of a frame, at the size of the file: 20 MB for an HD photo.
    /// The result is the caller's alone: it takes no place in the cache, whose
    /// budget is for the tiles of the chat.
    func loadFullSize(fileId: String) async -> UIImage? {
        await withFileOperation(fileId: fileId, priority: .requested, requester: UUID()) { operation in
            guard let data = await fetchData(fileId: fileId, operation: operation),
                  operation.isValid, !Task.isCancelled else { return nil }
            let decoder = thumbnailDecoder
            let maxPixels = AppConstants.UI.Viewer.maxPixelSize
            return await Task.detached(priority: .userInitiated) {
                await decoder(data, maxPixels)
            }.value
        }
    }

    /// Get raw Data for a fileId (for audio, etc.) - bypasses image decode.
    func loadData(fileId: String, priority: DownloadPriority = .onScreen, requester: UUID = UUID()) async -> Data? {
        await withFileOperation(fileId: fileId, priority: priority, requester: requester) { operation in
            await fetchData(fileId: fileId, operation: operation)
        }
    }

    /// Raw Data only if it is already cached or the transport already holds
    /// the whole file; never starts a download.
    func cachedData(fileId: String) async -> Data? {
        if let key = imageKeysByFile[fileId]?.first, let node = cache[key] {
            return node.entry.data
        }
        guard let url = await files.downloadedFileURL(fileId: fileId) else { return nil }
        return await Self.readFile(url)
    }

    /// Off the main actor; mapped, so the bytes are paged in as they are read.
    private nonisolated static func readFile(_ url: URL) async -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        return data
    }

    func reloadData(fileId: String, priority: DownloadPriority = .onScreen, requester: UUID = UUID()) async -> Data? {
        await withFileOperation(fileId: fileId, useCache: false, priority: priority, requester: requester) { operation in
            await fetchData(fileId: fileId, operation: operation)
        }
    }

    func loadSharedPlaybackFile(fileId: String) async -> URL? {
        await resolveSharedPlayback(fileId: fileId, useCache: true)
    }

    func reloadSharedPlaybackFile(fileId: String) async -> URL? {
        await resolveSharedPlayback(fileId: fileId, useCache: false)
    }

    /// What the decoded bitmaps of the cache take.
    var decodedImageBytes: Int { decodedByteCount }

    /// Lets the least recently used bitmaps go until the rest take at most
    /// `bytes`. A picture comes back from the file TDLib keeps, decoded
    /// again. Loads in progress are left alone: they finish and store their
    /// picture as usual. A view that shows a picture keeps it; the cache only
    /// stops holding it.
    func trim(toDecodedBytes bytes: Int) {
        while decodedByteCount > max(bytes, 0), let oldest = head {
            remove(oldest)
        }
    }

    /// Holds the cache to at most `bytes` of decoded bitmaps until
    /// `restoreDecodedByteLimit`: the least recently used ones go now, and
    /// loads that finish later store their picture within the limit. A trim
    /// alone leaves the loads in flight to fill the cache again before the app
    /// is suspended.
    func limitDecodedBytes(to bytes: Int) {
        decodedByteLimit = min(max(bytes, 0), Self.maxDecodedBytes)
        trim(toDecodedBytes: decodedByteLimit)
    }

    /// The cache may grow to its full budget again.
    func restoreDecodedByteLimit() {
        decodedByteLimit = Self.maxDecodedBytes
    }

    /// Deletes the playback copy of `fileId` once the player that read it has
    /// closed. The removal is queued before any later copy, so a video opened
    /// again at once keeps its new copy. TDLib's own file stays.
    func removeSharedPlaybackFile(fileId: String) {
        playbackFiles.remove(fileId: fileId)
    }

    /// Keeps `fileIds` out of the cache from now on and drops what it holds of
    /// them, a playback copy included. A load still answers its caller; the
    /// next one reads the file again from TDLib, which deletes it when the
    /// message destroys itself.
    func excludeFromCache(fileIds: Set<String>) {
        uncachedFileIds.formUnion(fileIds)
        for fileId in fileIds {
            for key in imageKeysByFile[fileId] ?? [] {
                if let node = cache[key] { remove(node) }
            }
            playbackFiles.remove(fileId: fileId)
        }
    }

    func invalidate(fileId: String) {
        if let operation = fileOperations.removeValue(forKey: fileId) {
            operation.invalidate()
        }
        for key in imageKeysByFile[fileId] ?? [] {
            if let node = cache[key] { remove(node) }
        }
        playbackFiles.remove(fileId: fileId)
    }

    func clear() {
        for operation in fileOperations.values {
            operation.invalidate()
        }
        fileOperations.removeAll()
        cache.removeAll()
        imageKeysByFile.removeAll()
        // File ids number the files of one TDLib instance; after a new session
        // the same id names another file.
        uncachedFileIds.removeAll()
        decodedByteCount = 0
        head = nil
        tail = nil
        playbackFiles.clear()
    }

    /// Deletes the video copies of earlier runs. File ids are numbered per
    /// TDLib instance, so a copy left in the app group names another file by
    /// now and nothing would ever remove it. Call it before the first video
    /// is opened.
    func removePlaybackCopiesOfEarlierRuns() {
        playbackFiles.clear()
    }

    /// Deletes the copies an earlier version kept in Caches/media_cache, up to
    /// 25 MB of what TDLib also holds. Off the main actor.
    nonisolated static func removeLegacyDiskCache(
        in caches: URL = FileManager.cachesDirectory
    ) async {
        let directory = caches.appendingPathComponent("media_cache", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Logger.app.warning("Failed to remove the old media cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func store(key: ImageKey, image: UIImage, data: Data) {
        guard !uncachedFileIds.contains(key.fileId) else { return }
        let entry = CacheEntry(image: image, data: data)
        guard entry.decodedBytes <= Self.maxDecodedBytes else { return }
        if let existing = cache[key] {
            decodedByteCount += entry.decodedBytes - existing.entry.decodedBytes
            existing.entry = entry
            moveToTail(existing)
            evictIfNeeded()
            return
        }
        let node = Node(key: key, entry: entry)
        cache[key] = node
        imageKeysByFile[key.fileId, default: []].insert(key)
        decodedByteCount += entry.decodedBytes
        appendToTail(node)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > Self.maxEntries || decodedByteCount > decodedByteLimit {
            guard let oldest = head else { break }
            remove(oldest)
        }
    }

    private func remove(_ node: Node) {
        cache.removeValue(forKey: node.key)
        decodedByteCount -= node.entry.decodedBytes
        imageKeysByFile[node.key.fileId]?.remove(node.key)
        if imageKeysByFile[node.key.fileId]?.isEmpty == true {
            imageKeysByFile[node.key.fileId] = nil
        }
        detach(node)
    }

    /// Detach `node` from the recency list (callers handle the hash map
    /// removal separately so this stays O(1) and side-effect-free).
    private func detach(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToTail(_ node: Node) {
        guard node !== tail else { return }
        detach(node)
        appendToTail(node)
    }

    private func appendToTail(_ node: Node) {
        if let currentTail = tail {
            currentTail.next = node
            node.prev = currentTail
        } else {
            head = node
        }
        tail = node
    }

    /// ImageIO decodes directly to the requested pixel size on the utility
    /// task, including orientation, without a full-size UIImage + CGContext.
    private nonisolated static func decodeThumbnail(_ data: Data, maxDimension: Int) -> UIImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
            ), let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ] as CFDictionary) else { return nil }
            return UIImage(cgImage: bitmap)
        }
    }

    private func withFileOperation<Result>(
        fileId: String,
        useCache: Bool = true,
        priority: DownloadPriority,
        requester: UUID,
        // Main actor, like every closure the cache passes: they read and
        // write its state around the transport calls they await.
        _ body: @MainActor (FileOperation) async -> Result?
    ) async -> Result? {
        guard !Task.isCancelled else { return nil }
        if !useCache { invalidate(fileId: fileId) }
        let operation = fileOperations[fileId] ?? FileOperation(priority: priority)
        fileOperations[fileId] = operation
        operation.join(requester, priority: priority)
        defer {
            operation.leave(requester)
            if !operation.hasReaders {
                // The last reader is gone, cancelled or done: a download
                // still running is wanted by nobody.
                operation.stopTransfers()
                if fileOperations[fileId] === operation {
                    fileOperations[fileId] = nil
                }
            }
        }
        let result = await body(operation)
        guard operation.isValid, !Task.isCancelled else { return nil }
        return result
    }

    /// Memory, then the shared transport request, with a validity check
    /// before publication.
    private func fetchData(fileId: String, operation: FileOperation) async -> Data? {
        guard operation.isValid, !Task.isCancelled else { return nil }
        if let key = imageKeysByFile[fileId]?.first, let node = cache[key] {
            // Sharing compressed bytes does not display this size's bitmap.
            // Only an actual image hit should refresh decoded-image recency.
            return node.entry.data
        }
        if let existing = operation.download {
            let data = await Self.value(of: existing)
            return operation.isValid && !Task.isCancelled ? data : nil
        }

        // Network fetch - deduplicated
        let priority = operation.priority
        let task = Task<Data?, Never> {
            do {
                let data = try await files.downloadFile(fileId: fileId, priority: priority)
                guard operation.isValid, !Task.isCancelled else { return nil }
                return data
            } catch {
                return nil
            }
        }
        operation.download = task
        let result = await Self.value(of: task)
        // The bytes stay with the operation for readers that join while it
        // lives; a failure is cleared so the next reader tries again. A reader
        // that left early leaves the task to the readers still waiting.
        if !Task.isCancelled, result == nil, operation.download == task {
            operation.download = nil
        }
        return operation.isValid && !Task.isCancelled ? result : nil
    }

    /// Waits for a transfer other readers may share, but returns nil as soon
    /// as the waiting task is cancelled, so a reader that is gone stops
    /// counting and the last one leaving can stop the download.
    private static func value<Value: Sendable>(of task: Task<Value?, Never>) async -> Value? {
        let wait = SharedTaskWait<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wait.begin(continuation)
                Task { await wait.end(task.value) }
            }
        } onCancel: {
            wait.end(nil)
        }
    }

    /// Resolves a file into the shared playback directory: a copy of the file the
    /// transport already holds, or else a write of its downloaded data.
    private func resolveSharedPlayback(fileId: String, useCache: Bool) async -> URL? {
        await withFileOperation(fileId: fileId, useCache: useCache, priority: .requested, requester: UUID()) { operation in
            switch await transportFile(fileId: fileId, operation: operation) {
            case .url(let sourceURL):
                guard operation.isValid, !Task.isCancelled else { return nil }
                return await playbackFiles.copy(sourceURL, fileId: fileId)
            case .unsupported:
                guard let data = await fetchData(fileId: fileId, operation: operation),
                      operation.isValid, !Task.isCancelled else { return nil }
                return await playbackFiles.write(data, fileId: fileId)
            case .failed, nil:
                // Reading the data would repeat the request that just failed.
                return nil
            }
        }
    }

    /// The transport's own copy of the file, through one request the readers
    /// of this file share; nil when the waiting task is cancelled.
    private func transportFile(fileId: String, operation: FileOperation) async -> TransportFile? {
        if let existing = operation.localFile {
            return await Self.value(of: existing)
        }
        let priority = operation.priority
        let task = Task<TransportFile?, Never> {
            do {
                return try await .url(files.localFileURL(fileId: fileId, priority: priority))
            } catch TelegramServiceError.unsupported {
                return .unsupported
            } catch {
                return .failed
            }
        }
        operation.localFile = task
        let outcome = await Self.value(of: task)
        // A failure is cleared so the next reader asks again.
        if !Task.isCancelled, case .failed? = outcome, operation.localFile == task {
            operation.localFile = nil
        }
        return outcome
    }
}

/// What the transport answered when asked for a file of its own.
private enum TransportFile: Sendable {
    case url(URL)
    /// The transport keeps no files of its own: its data is all there is.
    case unsupported
    /// The request failed. Downloading the data instead would repeat it.
    case failed
}

/// One wait for a shared task's value that ends early when the waiter is
/// cancelled. Whichever of `end(_:)` and `begin(_:)` comes second resumes
/// the continuation, exactly once.
private final class SharedTaskWait<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var outcome: Value??

    func begin(_ continuation: CheckedContinuation<Value?, Never>) {
        let ended: Value?? = lock.withLock {
            if outcome == nil { self.continuation = continuation }
            return outcome
        }
        if case .some(let value) = ended {
            continuation.resume(returning: value)
        }
    }

    func end(_ value: Value?) {
        let waiting: CheckedContinuation<Value?, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = .some(value)
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
