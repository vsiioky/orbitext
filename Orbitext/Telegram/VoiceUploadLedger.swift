import Foundation
import os
import Synchronization

/// Which copies of sent voice notes TDLib may still need.
///
/// sendMessage returns as soon as TDLib accepts the pending message, and TDLib
/// uploads the voice note from the copy later: a note sent offline stays
/// pending for hours, across relaunches of the app, and uploads when the
/// connection returns. A copy is therefore needed from before it is written
/// until TDLib reports the message sent, failed or deleted, whatever its age.
/// The record lives in a file beside the copies for the same reason: it has to
/// outlive the process.
final class VoiceUploadLedger: Sendable {
    /// The message a copy was sent as. `messageId` is 0 until sendMessage
    /// has returned.
    struct Entry: Codable, Equatable, Sendable {
        var chatId: Int64
        var messageId: Int64

        var isSent: Bool { messageId != 0 }
    }

    private struct MessageKey: Hashable, Sendable {
        let chatId: Int64
        let messageId: Int64
    }

    private struct State: Sendable {
        /// Nil until the file is read.
        var entries: [String: Entry]?
        /// Messages TDLib finished with lately, whether or not a copy was
        /// bound to them: its update can arrive before sendVoice has the
        /// message sendMessage returned to bind the copy to.
        var recentlyFinished: [MessageKey] = []
    }

    /// Enough to cover the time between sendMessage's response and the
    /// moment `bind` runs.
    private static let recentlyFinishedLimit = 32

    private let fileURL: URL
    private let state = Mutex(State())

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The copy `name` is about to be written, before sendMessage exists.
    func begin(_ name: String) {
        mutate { $0.entries?[name] = Entry(chatId: 0, messageId: 0) }
    }

    /// sendMessage returned `messageId` for the copy `name`.
    func bind(_ name: String, chatId: Int64, messageId: Int64) {
        mutate { state in
            if state.recentlyFinished.contains(MessageKey(chatId: chatId, messageId: messageId)) {
                state.entries?[name] = nil
            } else {
                state.entries?[name] = Entry(chatId: chatId, messageId: messageId)
            }
        }
    }

    /// The copy `name` was deleted, or never was written.
    func finish(_ name: String) {
        mutate { $0.entries?[name] = nil }
    }

    /// TDLib is done with these messages of `chatId`: sent, failed or deleted.
    func messagesFinished(chatId: Int64, messageIds: [Int64]) {
        mutate { state in
            for messageId in messageIds {
                let key = MessageKey(chatId: chatId, messageId: messageId)
                state.recentlyFinished.append(key)
                for (name, entry) in state.entries ?? [:] where entry.isSent && entry.chatId == chatId && entry.messageId == messageId {
                    state.entries?[name] = nil
                }
            }
            let overflow = state.recentlyFinished.count - Self.recentlyFinishedLimit
            if overflow > 0 { state.recentlyFinished.removeFirst(overflow) }
        }
    }

    /// The entry of the copy `name`, or nil when no message needs it.
    func entry(for name: String) -> Entry? {
        state.withLock { state in
            Self.loadIfNeeded(&state, from: fileURL)
            return state.entries?[name]
        }
    }

    /// For the session's wipe: the next account's copies are not these.
    func reset() {
        state.withLock { $0 = State(entries: [:]) }
    }

    /// Runs `change` on the loaded entries and writes the file if it changed them.
    private func mutate(_ change: (inout State) -> Void) {
        state.withLock { state in
            Self.loadIfNeeded(&state, from: fileURL)
            let before = state.entries
            change(&state)
            if state.entries != before { Self.write(state.entries ?? [:], to: fileURL) }
        }
    }

    private static func loadIfNeeded(_ state: inout State, from fileURL: URL) {
        guard state.entries == nil else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            state.entries = [:]
            return
        }
        do {
            state.entries = try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // Without the record every copy is unprotected; the copies are
            // kept by age, as before it existed.
            Logger.tdlib.warning("Voice upload record unreadable: \(error.localizedDescription, privacy: .public)")
            state.entries = [:]
        }
    }

    private static func write(_ entries: [String: Entry], to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // The session still knows; only a relaunch would not.
            Logger.tdlib.warning("Failed to save the voice upload record: \(error.localizedDescription, privacy: .public)")
        }
    }
}
