import Foundation
import os

// MARK: - Files on the device

extension TDLibService {
    /// What Clear cache asks TDLib to delete, named one by one: with an empty
    /// list optimizeStorage, like TDLib's daily clean-up, never deletes
    /// stickers, profile photos, thumbnails, wallpapers or notification
    /// sounds, and those stay for the life of the account.
    ///
    /// Left out: fileTypeUnknown, fileTypeNone, and the secret chat and
    /// Telegram Passport types, which the app does not use. A partial download
    /// in TDLib's temp directory is not left out by type: the file database
    /// gives it the real type of the file, so `clearImmunityDelay` protects it.
    static let clearableFileTypes = [
        "fileTypeAnimation", "fileTypeAudio", "fileTypeDocument", "fileTypeLivePhotoVideo",
        "fileTypeNotificationSound", "fileTypePhoto", "fileTypePhotoStory", "fileTypeProfilePhoto",
        "fileTypeSelfDestructingLivePhotoVideo", "fileTypeSelfDestructingPhoto", "fileTypeSelfDestructingVideo",
        "fileTypeSelfDestructingVideoNote", "fileTypeSelfDestructingVoiceNote", "fileTypeSticker",
        "fileTypeThumbnail", "fileTypeVideo", "fileTypeVideoNote", "fileTypeVideoStory", "fileTypeVoiceNote",
        "fileTypeWallpaper"
    ]

    /// How long after its last write a file stays out of Clear cache's reach,
    /// in seconds. TDLib decides by modification time alone: with 0 a download in
    /// progress, rewritten at every step, or one that finished a moment ago and
    /// is about to be read is unlinked under its user (and for a partial file
    /// TDLib is not told). An abandoned partial file goes once it is idle.
    static let clearImmunityDelay = 60

    /// What Clear cache can free of the session's files, and so what Settings
    /// counts: the downloaded media and the copies of sent voice notes. The
    /// database and the binlog beside them are not the cache.
    var cacheDirectories: [URL] { [filesPath, voiceUploadDirectory] }

    /// Deletes every file of those types now, whatever its age, size or chat,
    /// except what was written in the last `clearImmunityDelay` seconds.
    /// TDLib drops the local copy of each file it deletes, so a file shown
    /// again downloads again. optimizeStorage works on the device only, takes
    /// no throttle slot and has no timeout: it takes as long as the files are
    /// many.
    func clearFileCache() async throws {
        removeVoiceUploads(olderThan: 0)
        removeLegacyVoiceUploads()
        let deleted = try await localSendWithoutTimeout([
            "@type": "optimizeStorage",
            "size": 0,
            "ttl": 0,
            "count": 0,
            "immunity_delay": Self.clearImmunityDelay,
            "file_types": Self.clearableFileTypes.map { ["@type": $0] },
            "chat_ids": [Int64](),
            "exclude_chat_ids": [Int64](),
            "return_deleted_file_statistics": true,
            "chat_limit": 0
        ])
        let count = toInt64(deleted["count"])
        let megabytes = Double(toInt64(deleted["size"])) / 1_048_576
        Logger.tdlib.info(
            "Clear cache: TDLib deleted \(count, privacy: .public) files, \(megabytes, format: .fixed(precision: 1), privacy: .public) MB"
        )
    }

    // MARK: - Copies of sent voice notes

    /// TDLib uploads a voice note from a file after sendMessage returns, so
    /// the recording is copied here first. The copies are the session's: the
    /// session's wipe deletes the database directory with them, and Settings
    /// counts them as part of it.
    var voiceUploadDirectory: URL {
        dbPath.appendingPathComponent("voice-uploads", isDirectory: true)
    }

    /// Where earlier versions kept the copies, outside the database
    /// directory: they outlived a logout and were never counted.
    static var legacyVoiceUploadDirectory: URL {
        FileManager.appSupportDirectory.appendingPathComponent("voice-uploads", isDirectory: true)
    }

    /// A copy no message needs (the note was sent, failed or deleted, or
    /// belongs to a build that kept no record) stays this long unless the
    /// session ends or Clear cache runs.
    static var voiceUploadRetention: TimeInterval { 7 * 24 * 60 * 60 }

    /// A copy written but not yet bound to a message is a note being sent, or
    /// one whose app was killed before sendMessage returned. Past this age it
    /// is the second.
    static var voiceUploadUnsentGrace: TimeInterval { 60 * 60 }

    /// Even a note TDLib reports pending goes after this long: a lost update
    /// (the app was killed after TDLib delivered, before it recorded that)
    /// must not keep the audio for ever.
    static var voiceUploadPendingLimit: TimeInterval { 30 * 24 * 60 * 60 }

    func prepareVoiceUploadFile(_ data: Data) throws -> URL {
        removeVoiceUploads(olderThan: Self.voiceUploadRetention)
        try FileManager.default.createDirectory(at: voiceUploadDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).m4a"
        // Recorded first, so no sweep can see a copy nobody needs.
        voiceUploads.begin(name)
        let uploadURL = voiceUploadDirectory.appendingPathComponent(name)
        do {
            try data.write(to: uploadURL, options: .atomic)
        } catch {
            voiceUploads.finish(name)
            throw error
        }
        return uploadURL
    }

    func removeVoiceUploadFile(_ url: URL) {
        voiceUploads.finish(url.lastPathComponent)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.tdlib.warning("Failed to remove voice upload file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records that sendMessage accepted the note as `message`, which TDLib
    /// reports on when it is done with it.
    func bindVoiceUpload(_ url: URL, to message: MessageInfo) {
        voiceUploads.bind(url.lastPathComponent, chatId: message.chatId, messageId: message.id)
    }

    /// Lets go of the copies of the messages these updates say TDLib is done
    /// with: sent, failed to send, or deleted while pending.
    func releaseVoiceUploads(after update: [String: Any], type: String) {
        switch type {
        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            let chatId = toInt64((update["message"] as? [String: Any])?["chat_id"])
            let oldMessageId = toInt64(update["old_message_id"])
            guard chatId != 0, oldMessageId != 0 else { return }
            voiceUploads.messagesFinished(chatId: chatId, messageIds: [oldMessageId])
        case "updateDeleteMessages":
            // Dropped from TDLib's cache only: the message still exists.
            guard update["from_cache"] as? Bool != true else { return }
            let chatId = toInt64(update["chat_id"])
            let messageIds = (update["message_ids"] as? [Any] ?? []).map(toInt64)
            guard chatId != 0, !messageIds.isEmpty else { return }
            voiceUploads.messagesFinished(chatId: chatId, messageIds: messageIds)
        default:
            break
        }
    }

    /// Whether TDLib may still upload from the copy `name`, last written `age`
    /// seconds ago.
    private func voiceUploadIsNeeded(_ name: String, age: TimeInterval) -> Bool {
        guard let entry = voiceUploads.entry(for: name), age < Self.voiceUploadPendingLimit else { return false }
        return entry.isSent || age <= Self.voiceUploadUnsentGrace
    }

    /// Deletes the copies last written longer than `age` ago, except those of
    /// messages TDLib may still be sending.
    func removeVoiceUploads(olderThan age: TimeInterval, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: voiceUploadDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in files where fileURL.pathExtension == "m4a" {
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let fileAge = now.timeIntervalSince(modifiedAt)
            guard fileAge > age, !voiceUploadIsNeeded(fileURL.lastPathComponent, age: fileAge) else { continue }
            removeVoiceUploadFile(fileURL)
        }
    }

    /// Deletes the folder earlier versions kept the copies in, whatever their
    /// age: nothing writes there any more, so what is left is a previous
    /// session's audio, and no pending message of this version points into
    /// it. The session's wipe calls it, which deletes the current copies with
    /// the database directory; start() calls it again, so a removal that
    /// failed there is retried.
    func removeLegacyVoiceUploads() {
        let directory = Self.legacyVoiceUploadDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Logger.tdlib.warning("Failed to remove the old voice uploads, the next start retries: \(error.localizedDescription, privacy: .public)")
        }
    }
}
