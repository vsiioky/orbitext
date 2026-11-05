import UIKit
import XCTest
@testable import OrbitextWatch

@MainActor
final class StorageAuditTests: XCTestCase {
    func testDefaultFolderPinThrowsForServicesWithoutListSupport() async throws {
        let service = AuditStorageService()

        try await service.pinChat(chatId: 1, in: .main, isPinned: true)

        for list in [ChatListID.folder(7), .archive] {
            do {
                try await service.pinChat(chatId: 1, in: list, isPinned: true)
                XCTFail("pinning in \(list) must not look like success")
            } catch {
                XCTAssertTrue(error is ChatListActionError, "\(error)")
            }
        }
    }

    func testConcurrentFlushSendsEachQueuedMessageOnlyOnce() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let queue = MessageQueue(fileURL: file)
        queue.enqueue(chatId: 7, text: "Send once")
        let service = AuditStorageService()
        let manager = MessageManager(service: service, messageQueue: queue)

        let first = Task { await manager.flushMessageQueue() }
        await waitForArrival(service.sendGate)
        var secondReturned = false
        let second = Task { await manager.flushMessageQueue()
        secondReturned = true
        }
        // Let the second independently triggered flush reach the suspended send.
        for _ in 0..<100 {
            if await service.sendGate.arrivals == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(secondReturned, "A joining sync must wait for the shared drain")
        await service.sendGate.releaseAll()
        await first.value
        await second.value

        let sends = await service.sendGate.arrivals
        XCTAssertEqual(sends, 1, "One pending UUID must not be sent by two concurrent flush callers")
    }

    func testQueueDrainSkipsRemovedMessageAndIncludesNewlyQueuedMessage() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("queue-live-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let queue = MessageQueue(fileURL: file)
        queue.enqueue(chatId: 7, text: "First")
        queue.enqueue(chatId: 7, text: "Removed before send")
        let removedID = queue.pendingMessages[1].id
        let service = AuditStorageService()
        let manager = MessageManager(service: service, messageQueue: queue)
        let drain = Task { await manager.flushMessageQueue() }
        await waitForArrival(service.sendGate)
        queue.dequeue(removedID)
        queue.enqueue(chatId: 7, text: "Added while sending")
        await service.sendGate.releaseAll()
        await drain.value

        let sends = await service.sendGate.arrivals
        XCTAssertEqual(sends, 2)
        XCTAssertFalse(queue.hasPending, "The new entry must be drained; the deleted snapshot entry must not send")
    }

    func testCancellingAJoiningFlushDoesNotCancelItsOwner() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("queue-join-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let queue = MessageQueue(fileURL: file)
        queue.enqueue(chatId: 7, text: "First")
        queue.enqueue(chatId: 7, text: "Second")
        let service = AuditStorageService()
        let manager = MessageManager(service: service, messageQueue: queue)
        let owner = Task { await manager.flushMessageQueue() }
        await waitForArrival(service.sendGate)
        let joiner = Task { await manager.flushMessageQueue() }
        try await Task.sleep(for: .milliseconds(10))
        joiner.cancel()
        await service.sendGate.releaseAll()
        await owner.value
        await joiner.value

        let sends = await service.sendGate.arrivals
        XCTAssertEqual(sends, 2)
        XCTAssertFalse(queue.hasPending)
    }

    func testListCacheClearCannotBeUndoneByAnAlreadyStartedWrite() async {
        let cache = ListCache<StorageAuditPayload>(filename: "audit-list-\(UUID().uuidString).json")
        defer { cache.clear() }
        let barrier = StorageEncodingBarrier()
        cache.save([StorageAuditPayload(text: "previous-session", barrier: barrier)])

        let writer = Task.detached { cache.flush() }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        cache.clear()
        barrier.proceed.signal()
        await writer.value

        XCTAssertNil(cache.load(), "An old write must not restore cleared session data")
    }

    func testNewerListCacheWriteCannotBeReplacedByOlderEncoding() async {
        let cache = ListCache<StorageAuditPayload>(filename: "list-order-\(UUID()).json")
        defer { cache.clear() }
        let barrier = StorageEncodingBarrier()
        cache.save([StorageAuditPayload(text: "old", barrier: barrier)])
        let oldWriter = Task.detached { cache.flush() }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)

        cache.clear()
        cache.save([StorageAuditPayload(text: "new", barrier: nil)])
        cache.flush()
        barrier.proceed.signal()
        await oldWriter.value

        XCTAssertEqual(cache.load()?.map(\.text), ["new"])
    }

    func testFlushWaitsForAnAlreadyStartedCurrentWrite() async throws {
        let cache = ListCache<StorageAuditPayload>(filename: "list-flush-\(UUID()).json")
        defer { cache.clear() }
        let barrier = StorageEncodingBarrier()
        cache.save([StorageAuditPayload(text: "persist before suspension", barrier: barrier)])
        let writer = Task.detached { cache.flush() }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        var flushReturned = false
        let flushing = Task {
            await Task.detached { cache.flush() }.value
            flushReturned = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(flushReturned, "flush must not return while its current snapshot is still encoding")
        barrier.proceed.signal()
        await writer.value
        await flushing.value
        XCTAssertEqual(cache.load()?.map(\.text), ["persist before suspension"])
    }

    func testImageCacheClearReleasesImagesInMultipleEntryList() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let firstID = "audit-first-\(UUID().uuidString)"
        let secondID = "audit-second-\(UUID().uuidString)"
        service.downloadedFiles[firstID] = try makeImageData()
        service.downloadedFiles[secondID] = try makeImageData()

        let first = await captureImage(cache, fileId: firstID)
        let second = await captureImage(cache, fileId: secondID)
        XCTAssertNotNil(first.value)
        XCTAssertNotNil(second.value)
        cache.clear()
        await Task.yield()

        XCTAssertNil(first.value, "Clearing the LRU must release the first image, not retain a Node cycle")
        XCTAssertNil(second.value, "Clearing the LRU must release the second image")
    }

    func testImageCacheSingleEntryClearControlReleasesImage() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let id = "audit-single-\(UUID().uuidString)"
        service.downloadedFiles[id] = try makeImageData()
        let reference = await captureImage(cache, fileId: id)
        XCTAssertNotNil(reference.value)

        cache.clear()
        await Task.yield()

        XCTAssertNil(reference.value, "Control: a single node has no bidirectional reference cycle")
    }

    func testImageCacheClearRejectsResultFromPreviouslyStartedDownload() async {
        let service = AuditStorageService()
        let cache = ImageCache(service: service)
        let id = "audit-inflight-\(UUID().uuidString)"
        let oldLoad = Task { await cache.loadData(fileId: id) }
        await waitForArrival(service.downloadGate)

        cache.clear()
        await service.downloadGate.releaseAll()
        _ = await oldLoad.value

        let cached = await cache.cachedData(fileId: id)
        XCTAssertNil(cached, "A response started before clear/logout must not repopulate the cache")
    }

    func testOldImageDownloadCannotEraseReplacementOrItsJoinedCallers() async {
        let service = AuditStorageService()
        let cache = ImageCache(service: service)
        let id = "replacement-\(UUID())"
        let old = Task { await cache.loadData(fileId: id) }
        await waitForArrival(service.downloadGate)
        let replacement = Task { await cache.reloadData(fileId: id) }
        await waitForArrival(service.downloadGate, count: 2)
        await service.downloadGate.releaseFirst()
        let oldResult = await old.value
        XCTAssertNil(oldResult)

        let joiner = Task { await cache.loadData(fileId: id) }
        await waitForReaders(of: id, in: cache, count: 2)
        let count = await service.downloadGate.arrivals
        XCTAssertEqual(count, 2, "Old completion must not erase the newer in-flight operation")
        await service.downloadGate.releaseAll()
        let replacementData = await replacement.value
        let joinedData = await joiner.value
        XCTAssertEqual(replacementData, service.downloadData)
        XCTAssertEqual(joinedData, replacementData)
    }

    func testInvalidatingOneImageDoesNotDiscardAnotherFileDownload() async {
        let service = AuditStorageService()
        let cache = ImageCache(service: service)
        let firstID = "invalidate-\(UUID())", otherID = "keep-\(UUID())"
        let first = Task { await cache.loadData(fileId: firstID) }
        await waitForArrival(service.downloadGate)
        let other = Task { await cache.loadData(fileId: otherID) }
        await waitForArrival(service.downloadGate, count: 2)
        cache.invalidate(fileId: firstID)
        await service.downloadGate.releaseAll()
        let firstResult = await first.value
        let otherResult = await other.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(otherResult, service.downloadData)
    }

    func testClearedImageLoadCannotPublishDecodedImageIntoMemory() async throws {
        let service = try AuditStorageService(data: makeImageData())
        let cache = ImageCache(service: service)
        let id = "decoded-\(UUID())"
        defer { cache.clear() }
        let old = Task { await cache.load(fileId: id) }
        await waitForArrival(service.downloadGate)
        cache.clear()
        await service.downloadGate.releaseAll()
        let oldImage = await old.value
        XCTAssertNil(oldImage)
        let freshImage = await cache.load(fileId: id)
        XCTAssertNotNil(freshImage)
        let downloads = await service.downloadGate.arrivals
        XCTAssertEqual(downloads, 2, "A fresh load must not hit an image published after clear")
    }

    func testThumbnailSizesAreCachedIndependentlyAndReuseTheDownload() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let id = "thumbnail-sizes-\(UUID())"
        service.downloadedFiles[id] = try makeImageData(width: 320, height: 160)
        defer { cache.invalidate(fileId: id) }

        let smallResult = await cache.load(fileId: id, maxDimension: 68)
        let largeResult = await cache.load(fileId: id)
        let small = try XCTUnwrap(smallResult)
        let large = try XCTUnwrap(largeResult)
        XCTAssertEqual(small.cgImage?.width, 68)
        XCTAssertEqual(small.cgImage?.height, 34)
        XCTAssertEqual(large.cgImage?.width, 240)
        XCTAssertEqual(large.cgImage?.height, 120)

        let smallAgain = await cache.load(fileId: id, maxDimension: 68)
        let largeAgain = await cache.load(fileId: id)
        XCTAssertTrue(smallAgain === small, "Returning to the avatar must reuse its decoded bitmap")
        XCTAssertTrue(largeAgain === large, "The profile/default size must not overwrite the avatar size")
        XCTAssertEqual(service.requestedDownloads, [id])
    }

    func testConcurrentThumbnailLoadsShareOneDecode() async throws {
        let image = try XCTUnwrap(UIImage(data: makeImageData()))
        let probe = StorageThumbnailDecoderProbe(image: image)
        let service = MockTelegramService()
        let cache = ImageCache(service: service) { data, dimension in
            await probe.decode(data, dimension: dimension)
        }
        let id = "thumbnail-join-\(UUID())"
        service.downloadedFiles[id] = Data([1])
        defer { cache.invalidate(fileId: id) }

        let first = Task { await cache.load(fileId: id, maxDimension: 68) }
        await waitForArrival(probe.gate)
        let second = Task { await cache.load(fileId: id, maxDimension: 68) }
        for _ in 0..<20 { await Task.yield() }
        await probe.gate.releaseAll()
        let firstImage = await first.value
        let secondImage = await second.value

        XCTAssertNotNil(firstImage)
        XCTAssertTrue(firstImage === secondImage)
        let dimensions = await probe.dimensions
        XCTAssertEqual(dimensions, [68], "Joined callers must share decode as well as network work")
        XCTAssertEqual(service.requestedDownloads, [id])
    }

    func testCancellingThumbnailWaiterKeepsJoinedDecodeAlive() async throws {
        let image = try XCTUnwrap(UIImage(data: makeImageData()))
        let probe = StorageThumbnailDecoderProbe(image: image)
        let service = MockTelegramService()
        let cache = ImageCache(service: service) { data, dimension in
            await probe.decode(data, dimension: dimension)
        }
        let id = "thumbnail-cancel-\(UUID())"
        service.downloadedFiles[id] = Data([1])
        defer { cache.invalidate(fileId: id) }

        let cancelled = Task { await cache.load(fileId: id, maxDimension: 68) }
        await waitForArrival(probe.gate)
        let retained = Task { await cache.load(fileId: id, maxDimension: 68) }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        await probe.gate.releaseAll()
        let cancelledImage = await cancelled.value
        let retainedImage = await retained.value

        XCTAssertNil(cancelledImage)
        XCTAssertTrue(retainedImage === image)
        let dimensions = await probe.dimensions
        let decodeCancellations = await probe.cancellations
        XCTAssertEqual(dimensions, [68])
        XCTAssertEqual(decodeCancellations, [false])
        let warmImage = await cache.load(fileId: id, maxDimension: 68)
        XCTAssertTrue(warmImage === retainedImage)
    }

    func testClearDuringThumbnailDecodeCannotRepopulateMemory() async throws {
        let image = try XCTUnwrap(UIImage(data: makeImageData()))
        let probe = StorageThumbnailDecoderProbe(image: image)
        let service = MockTelegramService()
        let cache = ImageCache(service: service) { data, dimension in
            await probe.decode(data, dimension: dimension)
        }
        let id = "thumbnail-clear-\(UUID())"
        service.downloadedFiles[id] = Data([1])
        defer { cache.invalidate(fileId: id) }

        let old = Task { await cache.load(fileId: id, maxDimension: 68) }
        await waitForArrival(probe.gate)
        cache.clear()
        await probe.gate.releaseAll()
        let oldImage = await old.value
        XCTAssertNil(oldImage)
        let cancellations = await probe.cancellations
        XCTAssertEqual(cancellations, [true], "Clear must cancel the outstanding decode task")

        let fresh = await cache.load(fileId: id, maxDimension: 68)
        XCTAssertNotNil(fresh)
        let dimensions = await probe.dimensions
        XCTAssertEqual(dimensions, [68, 68], "A cleared decoder must not restore its memory entry")
        XCTAssertEqual(service.requestedDownloads, [id, id])
    }

    func testInvalidatedThumbnailDecodeCannotEraseItsReplacement() async throws {
        let image = try XCTUnwrap(UIImage(data: makeImageData()))
        let probe = StorageThumbnailDecoderProbe(image: image)
        let service = MockTelegramService()
        let cache = ImageCache(service: service) { data, dimension in
            await probe.decode(data, dimension: dimension)
        }
        let id = "thumbnail-replacement-\(UUID())"
        service.downloadedFiles[id] = Data([1])
        defer { cache.invalidate(fileId: id) }

        let old = Task { await cache.load(fileId: id, maxDimension: 68) }
        await waitForArrival(probe.gate)
        cache.invalidate(fileId: id)
        let replacement = Task { await cache.load(fileId: id, maxDimension: 68) }
        await waitForArrival(probe.gate, count: 2)
        await probe.gate.releaseFirst()
        let oldImage = await old.value
        XCTAssertNil(oldImage)

        let joined = Task { await cache.load(fileId: id, maxDimension: 68) }
        for _ in 0..<20 { await Task.yield() }
        await probe.gate.releaseAll()
        let replacedImage = await replacement.value
        let joinedImage = await joined.value
        XCTAssertNotNil(replacedImage)
        XCTAssertTrue(replacedImage === joinedImage)
        let dimensions = await probe.dimensions
        XCTAssertEqual(dimensions, [68, 68])
        XCTAssertEqual(service.requestedDownloads, [id, id])
    }

    func testDimensionVariantsRemainInsideTheImageEntryBudget() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let id = "thumbnail-variants-\(UUID())"
        service.downloadedFiles[id] = try makeImageData(width: 64, height: 64)
        defer { cache.invalidate(fileId: id) }
        let oldest = StorageWeakImage()
        oldest.value = await cache.load(fileId: id, maxDimension: 1)
        XCTAssertNotNil(oldest.value)

        for dimension in 2...51 {
            let image = await cache.load(fileId: id, maxDimension: CGFloat(dimension))
            XCTAssertNotNil(image)
        }

        XCTAssertNil(oldest.value, "Size variants count toward the same 50-bitmap LRU budget")
        XCTAssertEqual(service.requestedDownloads, [id])
    }

    func testThumbnailRejectsInvalidDimensionsWithoutDownloading() async {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        for dimension: CGFloat in [0, -1, .nan, .infinity] {
            let image = await cache.load(fileId: "unused", maxDimension: dimension)
            XCTAssertNil(image)
        }
        XCTAssertTrue(service.requestedDownloads.isEmpty)
    }

    func testSettingsClearRejectsAnInFlightStickerDownload() async {
        let service = AuditStorageService()
        let app = AppState(service: service, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(), preferences: AppPreferencesStore(defaults: makeTestDefaults()))
        app.networkMonitor.pause()
        let id = "settings-sticker-\(UUID())"
        defer {
            app.networkMonitor.pause()
            app.imageCache.invalidate(fileId: id)
        }
        // StickerView reads sticker files through the same cache as photos.
        let old = Task { await app.imageCache.loadData(fileId: id) }
        await waitForArrival(service.downloadGate)
        await app.clearCache()
        await service.downloadGate.releaseAll()
        let result = await old.value
        XCTAssertNil(result, "Settings clear must reject a sticker download that started before it")
    }

    func testStickerAndPhotoReadersOfOneFileShareOneDownload() async throws {
        let service = try AuditStorageService(data: makeImageData())
        let cache = ImageCache(service: service)
        let id = "shared-file-\(UUID())"
        defer { cache.invalidate(fileId: id) }

        let sticker = Task { await cache.loadData(fileId: id) }
        await waitForArrival(service.downloadGate)
        let photo = Task { await cache.load(fileId: id) }
        await waitForReaders(of: id, in: cache, count: 2)
        await service.downloadGate.releaseAll()
        let stickerData = await sticker.value
        let photoImage = await photo.value

        XCTAssertEqual(stickerData, service.downloadData)
        XCTAssertNotNil(photoImage)
        let downloads = await service.downloadGate.arrivals
        XCTAssertEqual(downloads, 1, "One file, one transport download, one owner to cancel it")
    }

    func testCachedDataNeverStartsADownload() async {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let id = "cached-only-\(UUID())"
        service.downloadedFiles[id] = Data([9])
        defer { cache.invalidate(fileId: id) }

        let before = await cache.cachedData(fileId: id)
        let loaded = await cache.loadData(fileId: id)
        let after = await cache.cachedData(fileId: id)

        XCTAssertNil(before)
        XCTAssertEqual(loaded, Data([9]))
        XCTAssertNil(after, "The mock keeps no file of its own to read")
        XCTAssertEqual(service.requestedDownloads, [id])
    }

    func testCachedDataReadsAFileTheTransportAlreadyHolds() async throws {
        let service = MockTelegramService()
        let cache = ImageCache(service: service)
        let held = "held-\(UUID())", missing = "missing-\(UUID())"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(held).tgs")
        try Data("sticker".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        service.localFileURLs[held] = file
        service.downloadedFiles[missing] = Data([1])

        let heldData = await cache.cachedData(fileId: held)
        let missingData = await cache.cachedData(fileId: missing)

        XCTAssertEqual(heldData, Data("sticker".utf8), "A sticker played in an earlier launch is still on disk")
        XCTAssertNil(missingData)
        XCTAssertTrue(service.requestedDownloads.isEmpty)
        XCTAssertTrue(service.requestedLocalFileURLs.isEmpty, "localFileURL would download a file it lacks")
    }

    private func waitForArrival(_ gate: StorageAuditGate, count: Int = 1) async {
        for _ in 0..<1000 {
            if await gate.arrivals >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Test setup never reached the controlled suspension")
    }

    /// Returns once `count` views wait for the file, so a test joins its
    /// readers before it lets the download finish.
    private func waitForReaders(of fileId: String, in cache: ImageCache, count: Int) async {
        for _ in 0..<2000 {
            if cache.readerCount(fileId: fileId) >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Test setup never reached \(count) readers")
    }

    private func captureImage(_ cache: ImageCache, fileId: String) async -> StorageWeakImage {
        let reference = StorageWeakImage()
        reference.value = await cache.load(fileId: fileId)
        return reference
    }

    private func makeImageData(width: Int = 2, height: Int = 2) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(UIImage(cgImage: XCTUnwrap(context.makeImage())).pngData())
    }
}

private final class StorageWeakImage {
    weak var value: UIImage?
}

private actor StorageThumbnailDecoderProbe {
    nonisolated let gate = StorageAuditGate()
    private let image: UIImage
    private(set) var dimensions: [Int] = []
    private(set) var cancellations: [Bool] = []

    init(image: UIImage) {
        self.image = image
    }

    func decode(_ data: Data, dimension: Int) async -> UIImage? {
        dimensions.append(dimension)
        await gate.arriveAndWait()
        cancellations.append(Task.isCancelled)
        return image
    }
}

private actor StorageAuditGate {
    private(set) var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func arriveAndWait() async {
        arrivals += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

private final class StorageEncodingBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
}

private struct StorageAuditPayload: Codable {
    let text: String
    let barrier: StorageEncodingBarrier?

    init(text: String, barrier: StorageEncodingBarrier?) {
        self.text = text
        self.barrier = barrier
    }

    init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
        barrier = nil
    }

    func encode(to encoder: Encoder) throws {
        if let barrier {
            barrier.entered.signal()
            _ = barrier.proceed.wait(timeout: .now() + 5)
        }
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

private final class AuditStorageService: TelegramServiceProtocol, @unchecked Sendable {
    let events = AsyncStream<TDLibEvent> { continuation in
        continuation.finish()
    }

    let sendGate = StorageAuditGate()
    let downloadGate = StorageAuditGate()
    let downloadData: Data

    init(data: Data = Data([4, 5, 6])) {
        downloadData = data
    }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        await downloadGate.arriveAndWait()
        return downloadData
    }

    func start() async {}
    func setPhoneNumber(_ phone: String) async throws {}
    func setAuthCode(_ code: String) async throws {}
    func setPassword(_ password: String) async throws {}
    func requestQRCodeAuthentication() async throws {}
    func logout() async throws {}
    func retryStartupIfNeeded() async throws -> Bool { false }
    func resetLocalSession() async throws {}
    func getChats(limit: Int, folderId: Int64?) async throws -> [ChatInfo] { [] }
    func getChat(chatId: Int64) async throws -> ChatInfo { throw TestError.failed("not implemented") }
    func getChat(username: String) async throws -> ChatInfo { throw TestError.failed("not implemented") }
    func notificationState(chatId: Int64) async throws -> ChatNotificationState { throw TestError.failed("not implemented") }
    func createPrivateChat(userId: Int64) async throws { throw TestError.failed("not implemented") }
    func getMessages(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [MessageInfo] { [] }
    func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64?) async throws -> MessageInfo {
        await sendGate.arriveAndWait()
        return MessageInfo(id: 42, chatId: chatId, senderName: "Audit", senderId: 7, content: .text(FormattedString(text: text)), date: Date(), isOutgoing: true, isRead: false)
    }
    func sendVoice(chatId: Int64, data: Data, duration: Int) async throws -> MessageInfo { throw TestError.failed("not implemented") }
    func deleteMessage(chatId: Int64, messageId: Int64) async throws {}
    func editMessage(chatId: Int64, messageId: Int64, newText: String) async throws -> MessageInfo { throw TestError.failed("not implemented") }
    func forwardMessage(fromChatId: Int64, messageId: Int64, toChatId: Int64) async throws {}
    func getMessageProperties(chatId: Int64, messageId: Int64) async throws -> MessageProperties { throw TestError.failed("not implemented") }
    func markAsRead(chatId: Int64, messageId: Int64) async throws {}
    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws {}
    func pinChat(chatId: Int64, isPinned: Bool) async throws {}
    func muteChat(chatId: Int64, isMuted: Bool) async throws {}
    func openChat(_ chatId: Int64) async {}
    func closeChat(_ chatId: Int64) async {}
    func openMessageContent(chatId: Int64, messageId: Int64) async {}
    func setReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {}
    func removeReaction(chatId: Int64, messageId: Int64, emoji: String) async throws {}
    func getAvailableMessageReactions(chatId: Int64, messageId: Int64) async throws -> [String] { [] }
    func sendTyping(chatId: Int64) async throws {}
    func searchMessages(query: String, chatId: Int64?) async throws -> [MessageInfo] { [] }
    func getChatFolders() async throws -> [ChatFolder] { [] }
    func setDraft(chatId: Int64, text: String?) async throws {}
    func getDraft(chatId: Int64) async throws -> String? { nil }
    func suspendForBackground() {}
    func resumeFromBackground() {}
    func updatePushDeviceToken(_ token: Data) async {}
    func handleRemotePush(payload: RemotePushPayload) async throws -> Bool { false }
    func getContact(userId: Int64) async throws -> ContactInfo { throw TestError.failed("not implemented") }
    func getContacts() async throws -> [ContactInfo] { [] }
    func searchContacts(query: String) async throws -> [ContactInfo] { [] }
    func getMe() async throws -> ContactInfo { throw TestError.failed("not implemented") }
    func getGroupInfo(chatId: Int64) async throws -> GroupInfo { throw TestError.failed("not implemented") }
    func clearFileCache() async throws {}
}
