import Foundation

/// Starting, restarting and ending the transport's session. Every transport
/// implements all of it, with no defaults: a reset that quietly did nothing
/// would report a wipe that never happened.
protocol TelegramSessionLifecycle: AnyObject, Sendable {
    func start() async
    /// Ends the session on the server within a bounded wait, then wipes it
    /// locally. Throws, wiping nothing, while shutdown is unconfirmed.
    func logout() async throws
    /// Re-runs a failed bootstrap without deleting the database or the
    /// credentials. Returns false when there is nothing to retry.
    func retryStartupIfNeeded() async throws -> Bool
    /// Closes the client and deletes the local session without contacting the
    /// server. Throws, deleting nothing, while shutdown is unconfirmed.
    func resetLocalSession() async throws
    func suspendForBackground()
    func resumeFromBackground()
    /// Which native client the events from now on come from. It advances,
    /// with a `clientGenerationChanged` event, whenever the client is
    /// installed or retired, so a consumer can tell a late event of a client
    /// it ended from the next session's.
    var clientGeneration: TDClientGeneration { get }
}

extension TelegramSessionLifecycle {
    /// A transport with one client for life never moves, and nothing is
    /// filtered. Unlike the requirements above, a forgotten override only
    /// costs the filtering; a forwarding double still needs its line.
    var clientGeneration: TDClientGeneration { .initial }
}

/// How soon a file is needed. TDLib downloads higher priorities first and,
/// among equal ones, the file asked for last.
enum DownloadPriority: Int, Comparable, Sendable {
    /// Behind everything else. The chat timeline no longer asks for it: a
    /// row outside the viewport requests no download at all.
    case offscreen = 1
    /// On screen: thumbnails, avatars, stickers, voice messages.
    case onScreen = 16
    /// Opened by the user: the photo viewer, the video player.
    case requested = 32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The priority of one download, which its owner may change while the
/// transport waits for the file: the user asks to play what a row shows. The transport sends the value current when the
/// download starts and moves the download on every later change.
final class DownloadPriorityHandle: @unchecked Sendable {
    typealias Observer = @Sendable (DownloadPriority) -> Void

    private let lock = NSLock()
    private var current: DownloadPriority
    private var observers: [UUID: Observer] = [:]

    init(_ priority: DownloadPriority) {
        current = priority
    }

    var value: DownloadPriority {
        lock.withLock { current }
    }

    func update(_ priority: DownloadPriority) {
        let observers: [Observer] = lock.withLock {
            guard current != priority else { return [] }
            current = priority
            return Array(self.observers.values)
        }
        observers.forEach { $0(priority) }
    }

    /// For the transport: `observer` hears every change from now on, until
    /// `removeObserver` is called with the returned token.
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = observer }
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.withLock { observers[token] = nil }
    }
}

/// Reading the transport's media. ImageCache and the players need only this,
/// so they take it instead of the whole service.
///
/// A download lasts as long as its caller waits: cancelling the calling task
/// stops it, so a file nobody shows any more costs no further traffic. Every
/// file has one owner (ImageCache), because the transport cannot tell two
/// callers of one file apart when one of them cancels.
protocol TelegramFileAccess: AnyObject, Sendable {
    /// The whole file, downloaded first if needed.
    func downloadFile(fileId: String, priority: DownloadPriorityHandle) async throws -> Data
    /// A completed file inside the transport's own storage, downloaded first
    /// if needed. The transport owns it: read or copy it, never move, modify
    /// or delete it. Transports without a file store keep the default, and
    /// callers then fall back to `downloadFile`.
    func localFileURL(fileId: String, priority: DownloadPriorityHandle) async throws -> URL
    /// The completed file inside the transport's own storage, or nil when the
    /// transport does not hold all of it. Never starts a download. The same
    /// ownership rules as `localFileURL` apply.
    func downloadedFileURL(fileId: String) async -> URL?
}

extension TelegramFileAccess {
    func localFileURL(fileId: String, priority: DownloadPriorityHandle) async throws -> URL {
        throw TelegramServiceError.unsupported
    }

    func downloadedFileURL(fileId: String) async -> URL? {
        nil
    }

    /// At a priority that does not change while the file downloads.
    func downloadFile(fileId: String, priority: DownloadPriority = .onScreen) async throws -> Data {
        try await downloadFile(fileId: fileId, priority: DownloadPriorityHandle(priority))
    }

    /// At a priority that does not change while the file downloads.
    func localFileURL(fileId: String, priority: DownloadPriority = .onScreen) async throws -> URL {
        try await localFileURL(fileId: fileId, priority: DownloadPriorityHandle(priority))
    }
}

/// Read-only facts about the transport for Settings and the cache size. A
/// transport without them keeps the nil defaults, which callers already treat
/// as "nothing to show".
protocol TelegramDiagnostics: AnyObject, Sendable {
    /// The directories whose contents Clear cache deletes: what the cache
    /// size in Settings counts of the transport. Its database stays out.
    var cacheDirectories: [URL] { get }
    /// Seconds left of an active FLOOD_WAIT, or nil without one.
    func currentFloodWaitRemaining() -> Int?
    /// Request telemetry; nil unless the build enables it.
    var telemetry: TDRequestTelemetry? { get }
}

extension TelegramDiagnostics {
    var cacheDirectories: [URL] { [] }
    func currentFloodWaitRemaining() -> Int? { nil }
    var telemetry: TDRequestTelemetry? { nil }
}
