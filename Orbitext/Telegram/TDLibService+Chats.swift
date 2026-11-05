import Foundation
import os

// MARK: - Chat list, folders, pin, mute, mark-as-read

extension TDLibService {
    func getChats(limit: Int, folderId: Int64? = nil) async throws -> [ChatInfo] {
        try await getChatPage(limit: limit, folderId: folderId).chats
    }

    func getChatPage(limit: Int, folderId: Int64? = nil) async throws -> ChatPage {
        let totalStart = ContinuousClock.now
        let chatList = ChatListID(folderId: folderId)
        if AppLogSettings.verboseTDInternals {
            Logger.tdlib.debug(
                "getChats start: limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
            )
        }

        func requestChats(timingLabel: String) async throws -> [String: Any] {
            let requestStart = ContinuousClock.now
            if AppLogSettings.verboseTDTransport {
                Logger.network.debug("-> getChats limit=\(limit)")
            }
            let result = try await throttledSend([
                "@type": "getChats",
                "chat_list": chatList.tdRequest,
                "limit": limit
            ])
            Logger.network.debug(
                "getChats timing: \(timingLabel, privacy: .public)=\(ContinuousClock.now - requestStart, privacy: .public) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
            )
            return result
        }

        var result: [String: Any]
        do {
            result = try await requestChats(timingLabel: "request")
            let returnedCount = normalizeArray(result["chat_ids"])?.count ?? 0
            if returnedCount < limit {
                Logger.network.debug(
                    "getChats direct page short: ids=\(returnedCount) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
                )
                let loadStart = ContinuousClock.now
                do {
                    try await coalescedLoadChats(chatList: chatList, limit: limit, reason: "pagination-short-page")
                    Logger.network.debug(
                        "getChats timing: loadChats warmup=\(ContinuousClock.now - loadStart, privacy: .public) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
                    )
                    result = try await requestChats(timingLabel: "postWarmRequest")
                } catch {
                    Logger.network.warning(
                        "pagination loadChats failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            } else {
                Logger.network.debug(
                    "getChats direct page complete: ids=\(returnedCount) limit=\(limit) skippedLoadChats=true folder=\(String(describing: folderId), privacy: .public)"
                )
            }
        } catch {
            if case TDError.api(_, let message) = error, message == "Chat list not found" {
                Logger.network.warning("getChats returned 'Chat list not found', retrying with loadChats")
                let retryLoadStart = ContinuousClock.now
                do {
                    try await coalescedLoadChats(chatList: chatList, limit: limit, reason: "chat-list-not-found")
                    Logger.network.debug(
                        "getChats timing: retry loadChats=\(ContinuousClock.now - retryLoadStart, privacy: .public) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
                    )
                } catch {
                    Logger.network.warning("loadChats retry FAILED: \(error.localizedDescription, privacy: .public)")
                }
                result = try await requestChats(timingLabel: "retryRequest")
            } else {
                throw error
            }
        }

        guard let chatIds = normalizeArray(result["chat_ids"]) else {
            if AppLogSettings.verboseTDInternals {
                Logger.tdlib.debug("getChats returned no chat_ids")
            }
            return ChatPage(chats: [], isComplete: false)
        }
        if AppLogSettings.verboseTDInternals {
            Logger.tdlib.debug("getChats received \(chatIds.count) chat ids")
            let chatIdValues = chatIds.map { toInt64($0) }
            Logger.network.info("getChats chatIds=\(chatIdValues)")
        }

        // Cooperatively yield once so any updateNewChat events queued behind
        // this task on the update dispatcher have a chance to drain into
        // chatCache before we read it. We deliberately avoid a fixed sleep
        // here - the explicit parallel getChat fallback below handles
        // anything not yet in cache deterministically.
        await Task.yield()

        // First pass: collect cached chats, identify misses
        let cacheScanStart = ContinuousClock.now
        var chats: [ChatInfo?] = Array(repeating: nil, count: chatIds.count)
        var missingIndices: [(Int, Int64)] = []
        for (index, rawId) in chatIds.enumerated() {
            let chatId = toInt64(rawId)
            if let chat = chatCache.get(chatId) {
                chats[index] = chat
            } else {
                missingIndices.append((index, chatId))
            }
        }
        Logger.network.debug(
            "getChats timing: cacheScan=\(ContinuousClock.now - cacheScanStart, privacy: .public) hits=\(chatIds.count - missingIndices.count) misses=\(missingIndices.count) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
        )
        if !missingIndices.isEmpty {
            let missingSample = missingIndices.prefix(5).map(\.1)
            let idSample = chatIds.prefix(5).map { toInt64($0) }
            Logger.network.debug(
                "getChats cache detail: cacheSize=\(self.chatCache.count) idSample=\(idSample, privacy: .public) missingSample=\(missingSample, privacy: .public) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
            )
        }

        // Parallel fetch for cache misses (throttle serializes sends,
        // but network round-trips overlap → much faster than sequential)
        let missFetchStart = ContinuousClock.now
        if !missingIndices.isEmpty {
            if AppLogSettings.verboseTDTransport {
                Logger.network.debug("getChats: \(missingIndices.count) cache misses, fetching in parallel")
            }
            await withTaskGroup(of: (Int, ChatInfo?).self) { group in
                for (index, chatId) in missingIndices {
                    group.addTask {
                        let info = try? await self.boundedCachedOrFetchChat(chatId: chatId)
                        return (index, info)
                    }
                }
                for await (index, chat) in group {
                    chats[index] = chat
                }
            }
        }
        if !missingIndices.isEmpty {
            Logger.network.debug(
                "getChats timing: missFetch=\(ContinuousClock.now - missFetchStart, privacy: .public) misses=\(missingIndices.count) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
            )
        }

        let result_chats = chats.compactMap(\.self)
        Logger.network.debug(
            "getChats timing: total=\(ContinuousClock.now - totalStart, privacy: .public) result=\(result_chats.count) ids=\(chatIds.count) misses=\(missingIndices.count) limit=\(limit) folder=\(String(describing: folderId), privacy: .public)"
        )
        if AppLogSettings.verboseTDInternals {
            Logger.tdlib.debug(
                "getChats completed: chats=\(result_chats.count) cacheMisses=\(missingIndices.count)"
            )
        }
        return ChatPage(chats: result_chats, isComplete: result_chats.count == chatIds.count)
    }

    func getChat(chatId: Int64) async throws -> ChatInfo {
        try await cachedOrFetchChat(chatId: chatId)
    }

    func createPrivateChat(userId: Int64) async throws {
        // A private chat's id is the user's id, so callers keep using it.
        // force: the contact list already made the user known, so TDLib
        // creates the chat locally instead of waiting for the network.
        _ = try await throttledSend(["@type": "createPrivateChat", "user_id": userId, "force": true])
    }

    func notificationState(chatId: Int64) async throws -> ChatNotificationState {
        // Answered from TDLib's memory and database: no throttle slot.
        let chat = try await localSend(["@type": "getChat", "chat_id": chatId])
        let settings = normalizeDictionary(chat["notification_settings"]) ?? [:]
        let chatIsMuted = toInt64(settings["mute_for"]) > 0
        let isMuted: Bool
        if settings["use_default_mute_for"] as? Bool ?? true,
           let scope = Self.notificationScope(of: normalizeDictionary(chat["type"])) {
            isMuted = await scopeIsMuted(scope) ?? chatIsMuted
        } else {
            isMuted = chatIsMuted
        }
        let positions = normalizeArray(chat["positions"]) ?? []
        let folderIds = Set(positions.compactMap { raw -> Int64? in
            guard let position = normalizeDictionary(raw),
                  toInt64(position["order"]) != 0,
                  let list = normalizeDictionary(position["list"]),
                  list["@type"] as? String == "chatListFolder" else { return nil }
            return toInt64(list["chat_folder_id"])
        })
        return ChatNotificationState(
            title: chat["title"] as? String ?? "",
            isMuted: isMuted,
            lastReadInboxMessageId: toInt64(chat["last_read_inbox_message_id"]),
            folderIds: folderIds
        )
    }

    private static let scopeSettingsTimeoutNanos: UInt64 = 2_000_000_000

    /// Best effort: the scope is normally cached, but on a fresh database
    /// TDLib asks the server; a slow answer must not hold the notification.
    private func scopeIsMuted(_ scope: String) async -> Bool? {
        guard let td = getTD() else { return nil }
        do {
            let settings = try await td.send(["@type": "getScopeNotificationSettings", "scope": ["@type": scope]],
                                             timeoutNanos: Self.scopeSettingsTimeoutNanos)
            return toInt64(settings["mute_for"]) > 0
        } catch {
            Logger.tdlib.warning("Scope notification settings unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The settings scope whose mute applies to a chat that uses the default.
    private static func notificationScope(of chatType: [String: Any]?) -> String? {
        switch chatType?["@type"] as? String {
        case "chatTypePrivate", "chatTypeSecret":
            return "notificationSettingsScopePrivateChats"
        case "chatTypeBasicGroup":
            return "notificationSettingsScopeGroupChats"
        case "chatTypeSupergroup":
            return chatType?["is_channel"] as? Bool == true
                ? "notificationSettingsScopeChannelChats"
                : "notificationSettingsScopeGroupChats"
        default:
            return nil
        }
    }

    func getChat(username: String) async throws -> ChatInfo {
        var normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedUsername.hasPrefix("@") {
            normalizedUsername.removeFirst()
        }
        guard !normalizedUsername.isEmpty else { throw TDError.chatNotFound }

        let chatResult = try await throttledSend([
            "@type": "searchPublicChat",
            "username": normalizedUsername
        ])
        let info = parseChatInfo(chatResult)
        chatCache.set(info.id, info)
        return info
    }

    func getChatFolders() async throws -> [ChatFolder] {
        // Try new API first (getChatFolders), fall back to old API (getChatFilters)
        let result: [String: Any]
        let folderInfos: [[String: Any]]

        do {
            result = try await throttledSend(["@type": "getChatFolders"])
            folderInfos = result["chat_folders"] as? [[String: Any]] ?? []
        } catch {
            // Old TDLib - use getChatFilters
            let filtersResult = try await throttledSend(["@type": "getChatFilters"])
            folderInfos = filtersResult["chat_filters"] as? [[String: Any]] ?? []
        }

        var folders: [ChatFolder] = []
        for info in folderInfos {
            let folderId = toInt64(info["id"])
            let title = parseFolderTitle(info)
            let icon = (info["icon"] as? [String: Any])?["name"] as? String ?? "folder"
            folders.append(ChatFolder(id: folderId, title: title, iconName: icon, chatIds: []))
        }
        return folders
    }

    func pinChat(chatId: Int64, isPinned: Bool) async throws {
        try await pinChat(chatId: chatId, in: .main, isPinned: isPinned)
    }

    func pinChat(chatId: Int64, in list: ChatListID, isPinned: Bool) async throws {
        _ = try await throttledSend([
            "@type": "toggleChatIsPinned",
            "chat_list": list.tdRequest,
            "chat_id": chatId,
            "is_pinned": isPinned
        ])
    }

    func muteChat(chatId: Int64, isMuted: Bool) async throws {
        _ = try await throttledSend([
            "@type": "setChatNotificationSettings",
            "chat_id": chatId,
            "notification_settings": [
                "@type": "chatNotificationSettings",
                "use_default_mute_for": false,
                "mute_for": isMuted ? AppConstants.Mute.indefiniteDuration : 0
            ] as [String: Any]
        ])
    }

    /// Notify TDLib that a chat is on-screen.
    ///
    /// TDLib uses openChat / closeChat to keep that chat's history hot in its
    /// caches and to prioritize updates / file downloads for it. The calls
    /// are counted per chat, not a flag: the chat stays open, its messages
    /// are never unloaded and the views of its recent messages are polled,
    /// until every open has been matched by a close (ChatSessionModel sends
    /// one of each per stay in a chat). Errors are swallowed because failing
    /// to open a chat must not block the UI.
    func openChat(_ chatId: Int64) async {
        do {
            _ = try await throttledSend([
                "@type": "openChat",
                "chat_id": chatId
            ])
        } catch {
            Logger.tdlib.warning("openChat(\(chatId)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Notify TDLib that the user left a chat: the counterpart of one
    /// openChat.
    ///
    /// Call only when the user actually navigates out of the chat, never on
    /// background (background close would invalidate the hot
    /// caches that a quick foreground bounce relies on).
    func closeChat(_ chatId: Int64) async {
        do {
            _ = try await throttledSend([
                "@type": "closeChat",
                "chat_id": chatId
            ])
        } catch {
            Logger.tdlib.warning("closeChat(\(chatId)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tell TDLib the user actually consumed a message's content.
    ///
    /// For voice notes this marks them as listened (the unread dot disappears
    /// across all the user's devices). For view-once / self-destruct media
    /// this starts the destruction timer on the server. Advisory call -
    /// failures are logged but do not surface to the UI.
    func openMessageContent(chatId: Int64, messageId: Int64) async {
        do {
            _ = try await throttledSend([
                "@type": "openMessageContent",
                "chat_id": chatId,
                "message_id": messageId
            ])
        } catch {
            Logger.tdlib.warning(
                "openMessageContent(chat=\(chatId), msg=\(messageId)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func markAsRead(chatId: Int64, messageId: Int64) async throws {
        try await markAsRead(chatId: chatId, messageIds: [messageId])
    }

    func markAsRead(chatId: Int64, messageIds: [Int64]) async throws {
        guard !messageIds.isEmpty else { return }
        _ = try await throttledSend([
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": messageIds,
            "force_read": true
        ])
    }
}
