import Foundation
import os

extension MessageManager {
    // MARK: - Offline Queue

    func flushMessageQueue() async {
        guard !Task.isCancelled else { return }
        if let running = messageQueueFlushTask {
            await running.value
            return
        }

        let task = Task {
            defer { messageQueueFlushTask = nil }
            await drainMessageQueue()
        }
        messageQueueFlushTask = task
        // The initiating operation retains its cancellation contract. A second
        // caller joins the drain without gaining the ability to cancel it.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func drainMessageQueue() async {
        var attempted = Set<UUID>()
        // Re-read the queue after each await: removed entries must not send,
        // and messages enqueued during a drain should join the same operation.
        while let pending = messageQueue.sendableMessages.first(where: { !attempted.contains($0.id) }) {
            guard !Task.isCancelled else { return }
            attempted.insert(pending.id)
            do {
                _ = try await sendTextMessage(
                    chatId: pending.chatId,
                    text: pending.text,
                    replyToMessageId: pending.replyToMessageId
                )
                messageQueue.dequeue(pending.id)
                try await Task.sleep(for: .milliseconds(Int(AppConstants.Queue.floodWaitDelay * 1000)))
            } catch is CancellationError {
                return
            } catch TDError.unexpectedResponse {
                // TDLib accepted it; only its answer could not be parsed.
                messageQueue.dequeue(pending.id)
            } catch {
                guard !Task.isCancelled else { return }
                guard Self.isRetryableLater(error) else {
                    // Refused for good: show it as failed in the chat at once.
                    Logger.app.warning("Queued message refused: \(error.localizedDescription, privacy: .public)")
                    messageQueue.markFailed(pending.id)
                    continue
                }
                messageQueue.incrementRetry(pending.id)
                do {
                    try await Task.sleep(for: .seconds(AppConstants.Queue.failureBackoff))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    func cancelQueueFlush() {
        messageQueueFlushTask?.cancel()
    }

    func clearCache() {
        cancelQueueFlush()
        cachedContacts = nil
        contactListCache.clear()
    }
}
