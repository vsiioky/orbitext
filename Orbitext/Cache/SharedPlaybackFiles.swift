import Foundation
import os

/// The copies of videos that the WatchKit inline movie player reads, in the
/// app group's `media_playback` directory, one file per file id.
///
/// Copying a video is a multi-megabyte write, so every file operation runs on
/// one serial queue, never on the caller's thread (the main actor). Removals
/// and clears are queued and return at once; copies and writes suspend until
/// the queue answers. The queue keeps the order the operations were issued
/// in, so a removal issued before a new copy cannot delete that copy.
final class SharedPlaybackFiles: @unchecked Sendable {
    static let directoryName = "media_playback"

    private let resolveDirectory: @Sendable () -> URL?
    private let queue: DispatchQueue

    /// - Parameter directory: Resolved on the queue: looking up the app group
    ///   container can create it.
    init(
        directory: @escaping @Sendable () -> URL? = { SharedPlaybackFiles.appGroupDirectory() },
        queue: DispatchQueue = DispatchQueue(label: "Orbitext.SharedPlaybackFiles", qos: .userInitiated)
    ) {
        resolveDirectory = directory
        self.queue = queue
    }

    static func appGroupDirectory() -> URL? {
        // Source of truth for the app-group identifier is
        // AppConstants.App.widgetSuite. Do not hardcode the string here.
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.App.widgetSuite)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Copies a file the caller does not own, named after what its bytes hold.
    /// The copies of other videos go: one player is open at a time, and a copy
    /// nobody will play again would stay on the watch until Clear cache.
    func copy(_ sourceURL: URL, fileId: String) async -> URL? {
        await perform { [self] in
            let sourceExtension = sourceURL.pathExtension.lowercased()
            let pathExtension = Self.headerBytes(of: sourceURL).map(Self.detectMediaExtension)
                ?? (sourceExtension.isEmpty ? "mp4" : sourceExtension)
            guard let destinationURL = fileURL(fileId: fileId, pathExtension: pathExtension) else { return nil }
            removeCopies(where: { $0 != Self.safeName(fileId) })
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                return nil
            }
        }
    }

    /// Writes data into a copy, replacing the copies of other videos like `copy`.
    func write(_ data: Data, fileId: String) async -> URL? {
        await perform { [self] in
            guard let destinationURL = fileURL(fileId: fileId, pathExtension: Self.detectMediaExtension(data)) else {
                return nil
            }
            removeCopies(where: { $0 != Self.safeName(fileId) })
            do {
                try data.write(to: destinationURL, options: .atomic)
                return destinationURL
            } catch {
                return nil
            }
        }
    }

    func remove(fileId: String) {
        queue.async { [self] in
            removeCopies(where: { $0 == Self.safeName(fileId) })
        }
    }

    func clear() {
        queue.async { [self] in
            guard let directory = resolveDirectory(),
                  FileManager.default.fileExists(atPath: directory.path) else { return }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Logger.app.warning("Failed to clear shared playback dir: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private

    /// Runs `work` on the queue after everything issued before it.
    private func perform<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Deletes the copies whose name, without the extension, `shouldRemove`
    /// accepts. Runs on the queue.
    private func removeCopies(where shouldRemove: (String) -> Bool) {
        guard let directory = resolveDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where shouldRemove(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Runs on the queue.
    private func fileURL(fileId: String, pathExtension: String) -> URL? {
        guard let directory = resolveDirectory() else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Logger.app.error("Failed to create shared playback dir: \(error.localizedDescription, privacy: .public)")
        }
        return directory.appendingPathComponent(Self.safeName(fileId)).appendingPathExtension(pathExtension)
    }

    private static func safeName(_ fileId: String) -> String {
        fileId.replacingOccurrences(of: "/", with: "_")
    }

    /// The first bytes of a file, enough to recognize its container; nil when
    /// the file cannot be opened.
    private static func headerBytes(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) ?? Data()
    }

    static func detectMediaExtension(_ data: Data) -> String {
        guard data.count >= 12 else { return "mp4" }
        let bytes = [UInt8](data.prefix(16))

        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return "mkv"
        }
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if brand == "qt  " {
                return "mov"
            }
            if brand == "M4V " || brand == "M4VH" || brand == "M4VP" {
                return "m4v"
            }
            return "mp4"
        }
        return "mp4"
    }
}
