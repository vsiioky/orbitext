import Foundation
import Observation
import os

@MainActor
@Observable
final class MessageManager {
    let service: TelegramServiceProtocol
    let messageQueue: MessageQueue
    var errorPresenter: ErrorPresenter?
    var messageQueueFlushTask: Task<Void, Never>?

    /// Cached contacts - survives navigation and app restarts
    var cachedContacts: [ContactInfo]?
    let contactListCache = ListCache<ContactInfo>(filename: "cached_contacts.json")

    init(service: TelegramServiceProtocol, messageQueue: MessageQueue) {
        self.service = service
        self.messageQueue = messageQueue
        // Restore contacts from disk for instant UI. TDLib numbers files per
        // instance, so a saved photo id can name another file in this run;
        // the photos return with the contacts TDLib loads.
        self.cachedContacts = contactListCache.load()?.map { contact in
            var contact = contact
            contact.photoFileId = nil
            return contact
        }
    }

    // MARK: - Error Handling Helpers

    /// Performs an async action, shows error via errorPresenter on failure, and optionally plays haptic on
    /// success/failure.
    func perform(haptic: (() -> Void)? = nil, errorHaptic: (() -> Void)? = nil, _ action: () async throws -> Void) async {
        do {
            try await action()
            haptic?()
        } catch is CancellationError {
            // Task cancelled (e.g. navigated away) - not a user-visible error
        } catch {
            errorPresenter?.show(error)
            errorHaptic?()
        }
    }

    /// Performs an async action that returns a value, shows error via errorPresenter on failure, and returns a default
    /// value on failure.
    func fetch<T>(default defaultValue: T, showError: Bool = true, _ action: () async throws -> T) async -> T {
        do {
            return try await action()
        } catch is CancellationError {
            return defaultValue
        } catch {
            if showError { errorPresenter?.show(error) }
            return defaultValue
        }
    }
}
