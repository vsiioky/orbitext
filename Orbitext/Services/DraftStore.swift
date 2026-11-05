import Foundation

final class DraftStore: @unchecked Sendable {
    private var drafts: [Int64: String] = [:]
    private let persistence: JSONFileStore<[String: String]>
    private let lock = NSLock()

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        persistence = JSONFileStore(filename: "drafts.json", fileURL: fileURL, fileManager: fileManager, logContext: "DraftStore")
        load()
    }

    func getDraft(chatId: Int64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return drafts[chatId]
    }

    func setDraft(chatId: Int64, text: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let text, !text.isEmpty {
            drafts[chatId] = text
        } else {
            drafts.removeValue(forKey: chatId)
        }
        saveLocked()
    }

    func allDrafts() -> [Int64: String] {
        lock.lock()
        defer { lock.unlock() }
        return drafts
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        drafts.removeAll()
        saveLocked()
    }

    /// Must be called while lock is held.
    private func saveLocked() {
        let snapshot = drafts.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
        persistence.save(snapshot)
    }

    private func load() {
        guard let dict = persistence.load() else { return }

        drafts = dict.reduce(into: [Int64: String]()) { result, pair in
            if let id = Int64(pair.key) {
                result[id] = pair.value
            }
        }
    }
}
