import Foundation
import os

/// Lightweight disk-backed cache for Codable lists (chats, contacts).
/// Writes are coalesced to avoid excessive I/O on rapid updates.
final class ListCache<T: Codable>: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSCondition()
    private let ioQueue = DispatchQueue(label: "com.orbitext.listcache", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private struct PendingWrite {
        let items: [T]
        let generation: UInt64
    }
    private var pendingWrite: PendingWrite?
    private var generation: UInt64 = 0
    private var activeWrites: Set<UInt64> = []

    static var directory: URL {
        FileManager.appSupportDirectory.appendingPathComponent("Orbitext", isDirectory: true)
    }

    init(filename: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let dir = Self.directory
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(filename)
    }

    /// Deletes every cache file whose name starts with `prefix`, including
    /// `.corrupt-*` backups and files written by earlier launches that no
    /// instance in this process knows about. Clear live instances first so
    /// none of their pending writes can recreate a file.
    static func removeFiles(withPrefix prefix: String, fileManager: FileManager = .default) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                Logger.app.error("ListCache: failed to remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func load() -> [T]? {
        lock.lock()
        defer { lock.unlock() }
        // Distinguish "file does not exist" (cold start) from "file exists
        // but cannot be read" (transient I/O error) from "file decodes to
        // garbage" (real corruption). Only the last case preserves the
        // bad file under a .corrupt-<UUID> name so the next save does NOT
        // silently overwrite a potentially recoverable on-disk snapshot.
        // Matches the pattern used by DraftStore/MessageQueue.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if fileManager.fileExists(atPath: fileURL.path) {
                Logger.app.error(
                    "ListCache: failed to read \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }

        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            Logger.app.error(
                "ListCache: failed to decode \(self.fileURL.lastPathComponent, privacy: .public); preserving corrupt file: \(error.localizedDescription, privacy: .public)"
            )
            preserveCorruptStore()
            return nil
        }
    }

    private func preserveCorruptStore() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
        } catch {
            Logger.app.error(
                "ListCache: failed to preserve corrupt \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func save(_ items: [T]) {
        lock.lock()
        pendingSave?.cancel()
        generation &+= 1
        lock.broadcast()
        let savedGeneration = generation
        pendingWrite = PendingWrite(items: items, generation: savedGeneration)
        let work = DispatchWorkItem { [weak self] in
            self?.drainPendingSave(expectedGeneration: savedGeneration)
        }
        pendingSave = work
        lock.unlock()
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Run any pending coalesced write synchronously. Callers that know
    /// the app is about to suspend or terminate (handleEnteredBackground,
    /// logout) MUST invoke flush() so the in-flight write does not get
    /// dropped on the floor by watchOS's aggressive suspension policy.
    func flush() {
        lock.lock()
        let target = generation
        lock.unlock()
        if let pending = takePendingWrite(expectedGeneration: target) { write(pending) }
        lock.lock()
        defer { lock.unlock() }
        // A background drain may already own this snapshot. A synchronous
        // flush must wait for it, unless a newer save/clear superseded it.
        while generation == target && activeWrites.contains(target) { lock.wait() }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        lock.broadcast()
        pendingSave?.cancel()
        pendingSave = nil
        pendingWrite = nil
        // The deletion and final write commit share this lock. Encoding may
        // continue outside it, but its old generation cannot restore the file.
        try? fileManager.removeItem(at: fileURL)
    }

    private func takePendingWrite(expectedGeneration: UInt64? = nil) -> PendingWrite? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = pendingWrite,
              expectedGeneration == nil || expectedGeneration == pending.generation else { return nil }
        pendingSave?.cancel()
        pendingWrite = nil
        pendingSave = nil
        activeWrites.insert(pending.generation)
        return pending
    }

    private func drainPendingSave(expectedGeneration: UInt64) {
        if let pending = takePendingWrite(expectedGeneration: expectedGeneration) { write(pending) }
    }

    private func write(_ pending: PendingWrite) {
        defer {
            lock.lock()
            activeWrites.remove(pending.generation)
            lock.broadcast()
            lock.unlock()
        }
        do {
            let data = try JSONEncoder().encode(pending.items)
            lock.lock()
            defer { lock.unlock() }
            guard generation == pending.generation else { return }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.app.error("ListCache: save failed for \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
