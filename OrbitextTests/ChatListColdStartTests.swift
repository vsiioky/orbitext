import XCTest
@testable import OrbitextWatch

@MainActor
final class ChatListColdStartTests: XCTestCase {
    func testLateBootstrapStatusUpdatesPreserveRestoredChatsAfterEmptyInitialPage() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        XCTAssertTrue(repository.isInitialSyncComplete)
        XCTAssertEqual(repository.chats.map(\.id), fixture.cachedChats.map(\.id))

        // getChats may initially know fewer IDs than the persisted app cache.
        fixture.service.chats = []
        await repository.loadChats()
        repository.invalidateChatListPrefetch()
        XCTAssertEqual(repository.chatListLoadingState, .idle)

        for chat in fixture.cachedChats {
            fixture.native.handleUpdate([
                "@type": "updateNewChat",
                "chat": [
                    "id": chat.id, "title": chat.title,
                    "type": ["@type": "chatTypePrivate", "user_id": chat.id],
                    "positions": []
                ] as [String: Any]
            ])
            // A status update has no list membership information. The native
            // cache still has order=0 until the list positions arrive.
            fixture.native.handleUpdate([
                "@type": "updateUserStatus", "user_id": chat.id,
                "status": ["@type": "userStatusOnline", "expires": 2_000_000_000]
            ])
        }
        await fixture.applyNativeEvents()

        XCTAssertEqual(repository.chats.map(\.id), fixture.cachedChats.map(\.id),
                       "Late bootstrap fields must not erase the restored chat list")
        XCTAssertEqual(repository.chats.map(\.order), fixture.cachedChats.map(\.order))
        XCTAssertEqual(repository.chats.first?.isPinned, true)
        XCTAssertTrue(repository.chats.allSatisfy(\.isOnline))
        repository.chatListCache.flush()
        XCTAssertEqual(repository.chatListCache.load()?.map(\.id), fixture.cachedChats.map(\.id),
                       "A temporary lack of native positions must not overwrite the disk cache with an empty list")
    }

    func testExplicitMainListRemovalDuringRefreshSurvivesStalePageCompletion() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        fixture.service.chats = fixture.cachedChats
        fixture.service.getChatsDelay = .milliseconds(250)
        let load = Task { await repository.loadChats() }
        let deadline = ContinuousClock.now + .seconds(1)
        while fixture.service.getChatsRequests.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(fixture.service.getChatsRequests.isEmpty)
        XCTAssertEqual(repository.chatListLoadingState, .refresh)

        let removed = fixture.cachedChats[0]
        fixture.native.chatCache.set(removed.id, removed)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": removed.id,
            "position": [
                "@type": "chatPosition", "list": ["@type": "chatListMain"],
                "order": 0, "is_pinned": false
            ] as [String: Any]
        ])
        await fixture.applyNativeEvents()
        XCTAssertFalse(repository.chats.contains { $0.id == removed.id },
                       "An explicit main-list removal remains authoritative during a refresh")

        await load.value
        repository.invalidateChatListPrefetch()
        XCTAssertEqual(repository.chats.map(\.id), Array(fixture.cachedChats.dropFirst()).map(\.id),
                       "The older page response must not resurrect an explicitly removed chat")
        repository.chatListCache.flush()
        XCTAssertFalse(repository.chatListCache.load()?.contains { $0.id == removed.id } ?? true)
    }

    func testEmptyBootstrapLastMessageAndDraftPositionsDoNotRemoveRestoredRows() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let chat = fixture.cachedChats[0]
        fixture.native.handleUpdate([
            "@type": "updateNewChat", "chat": ["id": chat.id, "title": chat.title, "positions": []] as [String: Any]
        ])
        for type in ["updateChatLastMessage", "updateChatDraftMessage"] {
            fixture.native.handleUpdate(["@type": type, "chat_id": chat.id, "positions": []])
        }

        await fixture.applyNativeEvents()

        XCTAssertEqual(fixture.app.chatRepository.chats.map(\.id), fixture.cachedChats.map(\.id))
        XCTAssertEqual(fixture.app.chatRepository.chats.first?.order, chat.order)
        XCTAssertEqual(fixture.app.chatRepository.chats.first?.isPinned, true)
    }

    func testReplacementPositionsRemovePreviouslyConfirmedMainMembership() async {
        for type in ["updateChatLastMessage", "updateChatDraftMessage"] {
            let fixture = Fixture()
            defer { fixture.finish() }
            let chat = fixture.cachedChats[0]
            fixture.native.handleUpdate([
                "@type": "updateNewChat",
                "chat": ["id": chat.id, "title": chat.title, "positions": [Fixture.position(order: chat.order)]] as [String: Any]
            ])
            fixture.native.handleUpdate(["@type": type, "chat_id": chat.id, "positions": []])

            await fixture.applyNativeEvents()

            XCTAssertFalse(fixture.app.chatRepository.chats.contains { $0.id == chat.id }, type)
        }
    }

    func testLaterPositivePositionRestoresChatAfterRemoval() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let chat = fixture.cachedChats[0]
        fixture.native.chatCache.set(chat.id, chat)
        for order: Int64 in [0, 200] {
            fixture.native.handleUpdate([
                "@type": "updateChatPosition", "chat_id": chat.id,
                "position": Fixture.position(order: order)
            ])
        }

        await fixture.applyNativeEvents()

        XCTAssertEqual(fixture.app.chatRepository.chats.first?.id, chat.id)
        XCTAssertEqual(fixture.app.chatRepository.chats.first?.order, 200)
        XCTAssertEqual(fixture.app.chatRepository.chats.count, fixture.cachedChats.count)
    }

    func testGenericSnapshotCannotOverwriteNewerConfirmedPosition() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let chat = fixture.cachedChats[0]
        fixture.native.chatCache.set(chat.id, chat)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": chat.id, "position": Fixture.position(order: 200)
        ])
        // A full chat snapshot without positions (order 0) can arrive after
        // the native position. It must not overwrite the confirmed order.
        fixture.native.chatCache.set(chat.id, chat)
        fixture.native.handleUpdate([
            "@type": "updateUserStatus", "user_id": chat.id,
            "status": ["@type": "userStatusOnline", "expires": 2_000_000_000]
        ])

        await fixture.applyNativeEvents()

        XCTAssertEqual(fixture.app.chatRepository.chats.first?.order, 200)
        XCTAssertEqual(fixture.app.chatRepository.chats.first?.isOnline, true)
    }

    func testArchivePositionRemovesARestoredMainRowFromListAndFile() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let archived = fixture.cachedChats[1]
        // The chat was archived on the phone while the app was closed. The new
        // client announces it with an archive position and no Main position.
        fixture.native.handleUpdate([
            "@type": "updateNewChat",
            "chat": ["id": archived.id, "title": archived.title, "positions": [Fixture.archivePosition(order: 5)]] as [String: Any]
        ])

        await fixture.applyNativeEvents()

        let repository = fixture.app.chatRepository
        XCTAssertFalse(repository.chats.contains { $0.id == archived.id })
        XCTAssertEqual(repository.chats.count, fixture.cachedChats.count - 1)
        repository.chatListCache.flush()
        XCTAssertFalse(repository.chatListCache.load()?.contains { $0.id == archived.id } ?? true,
                       "A future launch must not restore the archived chat into Main")
    }

    func testIncompletePageDoesNotEvictDifferentCachedRows() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        var page = fixture.cachedChats
        page[0] = ChatInfo(id: 90_001, title: "Newly loaded", lastMessage: nil,
                           unreadCount: 0, isGroup: false, isMuted: false, order: 1)
        fixture.service.chats = page
        // A chat lookup failed, so the page may lack chats it should list.
        fixture.service.getChatsPageIsComplete = false

        await fixture.app.chatRepository.loadChats()

        XCTAssertEqual(fixture.app.chatRepository.chats.count, fixture.cachedChats.count + 1)
        XCTAssertTrue(fixture.app.chatRepository.chats.contains { $0.id == fixture.cachedChats[0].id })
        XCTAssertTrue(fixture.app.chatRepository.chats.contains { $0.id == 90_001 })
    }

    func testCompletePageEvictsCachedRowsInsideItsRangeOnly() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let gone = fixture.cachedChats[2]
        // TDLib lists the top of Main without the third cached chat, which has
        // left Main since the last launch, and does not reach the chats below.
        fixture.service.chats = fixture.cachedChats.prefix(5).filter { $0.id != gone.id }

        await fixture.app.chatRepository.loadChats()

        XCTAssertEqual(fixture.app.chatRepository.chats.map(\.id),
                       fixture.cachedChats.map(\.id).filter { $0 != gone.id })
    }

    func testResetDuringLoadRejectsOldPageAndMembership() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        fixture.service.chats = fixture.cachedChats
        fixture.service.getChatsDelay = .milliseconds(250)
        let load = Task { await repository.loadChats() }
        let deadline = ContinuousClock.now + .seconds(1)
        while fixture.service.getChatsRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(fixture.service.getChatsRequests.isEmpty)

        repository.resetLoadedState()
        await load.value

        XCTAssertTrue(repository.chats.isEmpty)
        XCTAssertNil(repository.chatListCache.load())
        XCTAssertFalse(repository.isInitialSyncComplete)
    }

    func testCompletedPrefetchCannotResurrectExplicitlyRemovedChat() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let chat = fixture.cachedChats[0]
        repository.prefetchedChatPage = PrefetchedChatPage(
            folderId: nil, limit: 20, chats: fixture.cachedChats, isComplete: true,
            startedAtRevision: repository.store.revision
        )
        fixture.native.chatCache.set(chat.id, chat)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": chat.id, "position": Fixture.position(order: 0)
        ])
        await fixture.applyNativeEvents()

        await repository.loadMoreChats()

        XCTAssertFalse(repository.chats.contains { $0.id == chat.id })
        XCTAssertTrue(fixture.service.getChatsRequests.isEmpty, "The completed prefetch should be consumed without another request")
    }

    func testReturningFromFolderDoesNotRestoreRemovedMainRowWhenRefreshFails() async {
        await assertRemovedMainRowIsNotRestored(cachedChatCount: 10)
    }

    func testEmptyMainCacheReplacesFolderRowsWhenRefreshFails() async {
        await assertRemovedMainRowIsNotRestored(cachedChatCount: 1)
    }

    private func assertRemovedMainRowIsNotRestored(cachedChatCount: Int) async {
        // An unstarted native service deterministically rejects the refresh;
        // it cannot make any network request or replace the restored cache.
        let fixture = Fixture(useNativeService: true, cachedChatCount: cachedChatCount)
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let chat = fixture.cachedChats[0]
        repository.loadedChatListFolderId = 700_001
        fixture.native.chatCache.set(chat.id, chat)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": chat.id, "position": Fixture.position(order: 0)
        ])
        await fixture.applyNativeEvents()
        XCTAssertTrue(repository.chats.contains { $0.id == chat.id }, "A main-list removal must not remove a folder row")
        repository.chatListCache.flush()
        XCTAssertFalse(repository.chatListCache.load()?.contains { $0.id == chat.id } ?? true,
                       "A future launch must not restore an already removed Main row from disk")

        await repository.loadChats()

        XCTAssertNil(repository.loadedChatListFolderId)
        XCTAssertFalse(repository.chats.contains { $0.id == chat.id })
        XCTAssertEqual(repository.chats.count, fixture.cachedChats.count - 1)
    }

    func testLaterGenericUpdateCannotPersistRemovedMainRowDuringFolderTransition() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let chat = fixture.cachedChats[0]
        repository.folders = [ChatFolder(id: 700_003, title: "Fixture folder", iconName: "folder", chatIds: [])]
        repository.selectedFolderId = 700_003
        repository.folderFilterEnabled = true
        repository.invalidateChatListPrefetch()
        fixture.native.chatCache.set(chat.id, chat)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": chat.id, "position": Fixture.position(order: 0)
        ])
        fixture.native.handleUpdate([
            "@type": "updateUserStatus", "user_id": chat.id,
            "status": ["@type": "userStatusOnline", "expires": 2_000_000_000]
        ])
        await fixture.applyNativeEvents()
        repository.chatListCache.flush()

        XCTAssertFalse(repository.chats.contains { $0.id == chat.id },
                       "Main is still on screen during the transition, and it no longer has the chat")
        XCTAssertFalse(repository.chatListCache.load()?.contains { $0.id == chat.id } ?? true)
    }

    func testNewNativeSessionKeepsRowsButRequiresFreshMembershipConfirmation() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let kept = fixture.cachedChats[0]
        let removed = fixture.cachedChats[1]
        fixture.native.chatCache.set(kept.id, kept)
        fixture.native.chatCache.set(removed.id, removed)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": kept.id, "position": Fixture.position(order: kept.order)
        ])
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": removed.id, "position": Fixture.position(order: 0)
        ])
        fixture.native.emit(.chatListSessionStarted)
        fixture.native.handleUpdate([
            "@type": "updateNewChat", "chat": ["id": kept.id, "title": kept.title, "positions": []] as [String: Any]
        ])
        fixture.native.handleUpdate(["@type": "updateChatLastMessage", "chat_id": kept.id, "positions": []])
        await fixture.applyNativeEvents()
        fixture.service.chats = fixture.cachedChats

        await fixture.app.chatRepository.loadChats()

        XCTAssertTrue(fixture.app.chatRepository.chats.contains { $0.id == kept.id })
        XCTAssertFalse(fixture.app.chatRepository.chats.contains { $0.id == removed.id })
    }

    func testMissingChatFetchCannotPublishIntoNewFolderScope() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let missing = fixture.cachedChats[0]
        repository.chats = []
        fixture.service.getChatDelay = .milliseconds(250)
        fixture.service.chatsById[missing.id] = missing
        repository.handleNewMessage(Fixture.message(chatID: missing.id))
        await fixture.waitForMissingChatRequest()
        let fetch = repository.missingChatFetchTask
        repository.loadedChatListFolderId = 700_002
        repository.chats = [fixture.cachedChats[1]]

        await fetch?.value

        XCTAssertEqual(repository.chats.map(\.id), [fixture.cachedChats[1].id])
    }

    func testMissingChatFetchPreservesNewerConfirmedPosition() async {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let missing = fixture.cachedChats[0]
        repository.chats = []
        fixture.service.getChatDelay = .milliseconds(250)
        fixture.service.chatsById[missing.id] = missing
        repository.handleNewMessage(Fixture.message(chatID: missing.id))
        await fixture.waitForMissingChatRequest()
        let fetch = repository.missingChatFetchTask
        fixture.native.chatCache.set(missing.id, missing)
        fixture.native.handleUpdate([
            "@type": "updateChatPosition", "chat_id": missing.id, "position": Fixture.position(order: 200)
        ])
        await fixture.applyNativeEvents()

        await fetch?.value

        XCTAssertEqual(repository.chats.first?.order, 200)
        XCTAssertEqual(repository.chats.first?.isPinned, true)
        XCTAssertEqual(repository.chats.first?.lastMessage?.id, 123)
    }

    // MARK: - File ids of the TDLib run that saved the file

    func testRestoredChatsCarryNoFileIdOfTheRunThatSavedThem() async {
        // TDLib numbers files per instance: in this run the saved id can name
        // another file, or none yet.
        let fixture = Fixture(useNativeService: true, withPhotos: true)
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        XCTAssertEqual(repository.chats.map(\.id), fixture.cachedChats.map(\.id))
        XCTAssertEqual(repository.chats.compactMap(\.photoFileId), [])

        let chat = fixture.cachedChats[1]
        fixture.native.handleUpdate([
            "@type": "updateNewChat",
            "chat": [
                "id": chat.id, "title": chat.title,
                "type": ["@type": "chatTypePrivate", "user_id": chat.id],
                "photo": ["@type": "chatPhotoInfo",
                          "small": ["@type": "file", "id": 8888, "size": 0, "expected_size": 0]],
                "positions": [Fixture.position(order: chat.order)]
            ] as [String: Any]
        ])
        await fixture.applyNativeEvents()

        XCTAssertEqual(repository.chat(id: chat.id)?.photoFileId, "8888", "TDLib's announcement brings this run's photo")
    }

    func testRestoredFolderChatsCarryNoFileIdOfTheRunThatSavedThem() {
        let fixture = Fixture()
        defer { fixture.finish() }
        let repository = fixture.app.chatRepository
        let folderId = Int64.random(in: 600_000...699_999)
        let folderFile = repository.cache(for: folderId)
        defer { folderFile.clear() }
        var row = ChatInfo(id: 90_001, title: "Folder chat", lastMessage: nil, unreadCount: 0,
                           isGroup: false, isMuted: false, order: 5, folderId: folderId)
        row.photoFileId = "4242"
        folderFile.save([row])
        folderFile.flush()

        XCTAssertTrue(repository.restoreCachedChats(for: folderId))

        XCTAssertEqual(repository.chats.map(\.id), [90_001])
        XCTAssertNil(repository.chats.first?.photoFileId)
    }

    @MainActor
    private final class Fixture {
        let service = MockTelegramService()
        let native = TDLibService()
        let app: AppState
        let cachedChats: [ChatInfo]
        private let priorCache: [ChatInfo]?

        init(useNativeService: Bool = false, cachedChatCount: Int = 10, withPhotos: Bool = false) {
            let cache = ListCache<ChatInfo>(filename: "cached_chats.json")
            priorCache = cache.load()
            var rows: [ChatInfo] = []
            for index in 1...cachedChatCount {
                let identifier = Int64(80_000 + index)
                let title = index == 1 ? "Saved Messages" : "Cached \(index)"
                let order = Int64(100 - index)
                var chat = ChatInfo(id: identifier, title: title, lastMessage: nil,
                                    unreadCount: 0, isGroup: false, isMuted: false,
                                    order: order, isPinned: index == 1)
                if withPhotos { chat.photoFileId = "\(700 + index)" }
                rows.append(chat)
            }
            cachedChats = rows
            cache.save(cachedChats)
            cache.flush()
            let appService: TelegramServiceProtocol
            if useNativeService { appService = native } else { appService = service }
            app = AppState(service: appService, notificationManager: MockNotificationManager(),
                           widgetSync: MockWidgetSync(),
                           preferences: AppPreferencesStore(defaults: makeTestDefaults()))
            // Deliberately do not initialize/start either service or the app:
            // only local TDLib update parsing and repository state are exercised.
        }

        func applyNativeEvents() async {
            native.session.finishEventsForTesting()
            for await event in native.events { app.handleEvent(event) }
        }

        static func position(order: Int64) -> [String: Any] {
            ["@type": "chatPosition", "list": ["@type": "chatListMain"], "order": order, "is_pinned": order > 0]
        }

        static func archivePosition(order: Int64) -> [String: Any] {
            ["@type": "chatPosition", "list": ["@type": "chatListArchive"], "order": order, "is_pinned": false]
        }

        static func message(chatID: Int64) -> MessageInfo {
            MessageInfo(id: 123, chatId: chatID, senderName: "Offline fixture", senderId: 1,
                        content: .text("Test incoming message"), date: .distantPast, isOutgoing: false, isRead: false)
        }

        func waitForMissingChatRequest() async {
            let deadline = ContinuousClock.now + .seconds(1)
            while service.getChatRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertFalse(service.getChatRequests.isEmpty)
        }

        func finish() {
            native.session.finishEventsForTesting()
            app.chatRepository.invalidateChatListPrefetch()
            app.chatRepository.missingChatFetchTask?.cancel()
            app.chatRepository.folderChatListCaches.values.forEach { $0.clear() }
            app.resetSyncPipeline()
            app.networkMonitor.pause()
            let cache = app.chatRepository.chatListCache
            if let priorCache {
                cache.save(priorCache)
                cache.flush()
            } else {
                cache.clear()
            }
        }
    }
}
