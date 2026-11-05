import Foundation
import Observation

@Observable
final class MessageQueue {
    var pendingMessages: [PendingMessage] = []

    struct PendingMessage: Identifiable, Codable {
        let id: UUID
        let chatId: Int64
        let text: String
        let replyToMessageId: Int64?
        let createdAt: Date
        var retryCount = 0
    }

    private let persistence: JSONFileStore<[PendingMessage]>

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        persistence = JSONFileStore(filename: "pending_messages.json", fileURL: fileURL, fileManager: fileManager, logContext: "MessageQueue")
        pendingMessages = persistence.load() ?? []
    }

    static let maxRetries = AppConstants.Queue.maxRetries

    var hasPending: Bool { !pendingMessages.isEmpty }

    var sendableMessages: [PendingMessage] {
        pendingMessages.filter { $0.retryCount < Self.maxRetries }
    }

    var failedMessages: [PendingMessage] {
        pendingMessages.filter { $0.retryCount >= Self.maxRetries }
    }

    @discardableResult
    func enqueue(chatId: Int64, text: String, replyToMessageId: Int64? = nil) -> UUID {
        let msg = PendingMessage(
            id: UUID(),
            chatId: chatId,
            text: text,
            replyToMessageId: replyToMessageId,
            createdAt: Date()
        )
        pendingMessages.append(msg)
        save()
        return msg.id
    }

    func dequeue(_ id: UUID) {
        pendingMessages.removeAll { $0.id == id }
        save()
    }

    func incrementRetry(_ id: UUID) {
        pendingMessages.update(where: id) { $0.retryCount += 1 }
        save()
    }

    /// Stops retrying; the chat shows the message with retry and remove.
    func markFailed(_ id: UUID) {
        pendingMessages.update(where: id) { $0.retryCount = Self.maxRetries }
        save()
    }

    func pendingFor(chatId: Int64) -> [PendingMessage] {
        pendingMessages.filter { $0.chatId == chatId }
    }

    func retryFailed(_ id: UUID) {
        pendingMessages.update(where: id) { $0.retryCount = 0 }
        save()
    }

    func removeFailed(_ id: UUID) {
        dequeue(id)
    }

    func clear() {
        pendingMessages.removeAll()
        save()
    }

    private func save() {
        persistence.save(pendingMessages)
    }
}
