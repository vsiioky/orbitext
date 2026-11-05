import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import OrbitextWatch

/// A transport's files for the media views: downloads that wait until the
/// test releases them, and a record of which were started, with what
/// priority, and which their callers gave up on.
final class RecordingFiles: TelegramFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var startedIds: [String] = []
    private var cancelledIds: [String] = []
    private var priorities: [String: DownloadPriorityHandle] = [:]
    private var localFiles: [String: URL] = [:]
    private var isReleased = false
    private var areLookupsPaused = false
    private var lookupCount = 0
    private var finishedLookupCount = 0
    private let payload: Data

    /// `payload` is what a finished download returns; by default a small valid image.
    init(payload: Data = RecordingFiles.imageData()) {
        self.payload = payload
    }

    var started: [String] { lock.withLock { startedIds } }
    var cancelled: [String] { lock.withLock { cancelledIds } }
    /// How many times the transport was asked whether it holds a file, and
    /// how many of those answered.
    var lookups: Int { lock.withLock { lookupCount } }
    var finishedLookups: Int { lock.withLock { finishedLookupCount } }

    func priority(of fileId: String) -> DownloadPriorityHandle? {
        lock.withLock { priorities[fileId] }
    }

    /// Lets every waiting and later download finish.
    func release() {
        lock.withLock { isReleased = true }
    }

    /// The transport already holds this file: `downloadedFileURL` reports it.
    func hold(fileId: String, at url: URL) {
        lock.withLock { localFiles[fileId] = url }
    }

    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data {
        lock.withLock {
            startedIds.append(fileId)
            priorities[fileId] = priority
        }
        do {
            while !lock.withLock({ isReleased }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            lock.withLock { cancelledIds.append(fileId) }
            throw error
        }
        return payload
    }

    /// Makes `downloadedFileURL` wait, so a test can act while the transport
    /// is still looking for a file.
    func pauseLookups() {
        lock.withLock { areLookupsPaused = true }
    }

    func resumeLookups() {
        lock.withLock { areLookupsPaused = false }
    }

    func downloadedFileURL(fileId: String) async -> URL? {
        lock.withLock { lookupCount += 1 }
        while lock.withLock({ areLookupsPaused }) {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        }
        return lock.withLock {
            finishedLookupCount += 1
            return localFiles[fileId]
        }
    }

    /// A PNG of one color, `width` by `height` pixels.
    static func imageData(width: Int = 8, height: Int = 8) -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
