import Foundation
import os

/// Synchronous JSON persistence shared by durable stores. Callers own any
/// locking and in-memory state; a successful save is on disk before returning.
struct JSONFileStore<Value: Codable> {
    private let fileURL: URL
    private let fileManager: FileManager
    private let logContext: String

    init(filename: String, fileURL: URL? = nil, fileManager: FileManager = .default, logContext: String) {
        self.fileURL = fileURL ?? FileManager.appSupportDirectory
            .appendingPathComponent("Orbitext", isDirectory: true)
            .appendingPathComponent(filename)
        self.fileManager = fileManager
        self.logContext = logContext

        do {
            try fileManager.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logFailure("create directory", error: error)
        }
    }

    func save(_ value: Value) {
        do {
            try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        } catch {
            logFailure("save", error: error)
        }
    }

    func load() -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // An unreadable file may be recoverable. Only a decode failure
            // means corruption; a missing file is a normal first launch.
            if fileManager.fileExists(atPath: fileURL.path) {
                logFailure("read", error: error)
            }
            return nil
        }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            logFailure("decode; preserving corrupt file", error: error)
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
            logFailure("preserve corrupt file", error: error)
        }
    }

    private func logFailure(_ operation: String, error: Error) {
        Logger.app.error("\(self.logContext, privacy: .public): failed to \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}
