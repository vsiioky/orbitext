import XCTest
@testable import OrbitextWatch

/// The chat directory and the per-list positions, without a repository.
final class ChatStoreTests: XCTestCase {
    private var store = ChatStore()

    // MARK: - Position events

    func testExplicitZeroOrderTombstonesOnlyThatList() {
        announce(1, main: 5, folder7: 4)

        let change = store.applyPositions(explicit(1, main(0)))

        XCTAssertEqual(ids(.main), [])
        XCTAssertEqual(ids(.folder(7)), [1])
        XCTAssertEqual(store.entries[.main]?[1]?.isTombstone, true)
        XCTAssertEqual(change.tombstoned, [.main: [1]])
        XCTAssertTrue(change.lists.contains(.main))
    }

    func testTombstoneIsRecordedEvenForAChatThatWasNeverListed() {
        _ = store.applyFields(chat(9))

        let change = store.applyPositions(explicit(9, main(0)))

        XCTAssertEqual(store.entries[.main]?[9]?.isTombstone, true)
        XCTAssertEqual(change.tombstoned, [.main: [9]])
    }

    func testRepeatedTombstoneReportsNoChange() {
        announce(1, main: 5)
        _ = store.applyPositions(explicit(1, main(0)))

        let change = store.applyPositions(explicit(1, main(0)))

        XCTAssertTrue(change.tombstoned.isEmpty)
        XCTAssertFalse(change.lists.contains(.main))
    }

    func testPositiveUpdateEndsATombstone() {
        announce(1, main: 5)
        _ = store.applyPositions(explicit(1, main(0)))

        _ = store.applyPositions(explicit(1, main(8, pinned: true)))

        XCTAssertEqual(ids(.main), [1])
        XCTAssertEqual(store.chats(in: .main).first?.order, 8)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)
    }

    func testReplacementTombstonesOnlyListsConfirmedThisSession() {
        announce(1, main: 5, folder7: 4)

        let change = store.applyPositions(replacement(1, main(6)))

        XCTAssertEqual(store.chats(in: .main).first?.order, 6)
        XCTAssertEqual(ids(.folder(7)), [], "the vector no longer lists folder 7")
        XCTAssertEqual(change.tombstoned, [.folder(7): [1]])
        XCTAssertNil(store.entries[.archive]?[1], "a list the chat never had is not invented")
    }

    func testReplacementKeepsSnapshotEntriesFromDisk() {
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .restore)

        let change = store.applyPositions(replacement(1))

        XCTAssertEqual(ids(.main), [1], "an empty vector says nothing about a row restored from disk")
        XCTAssertEqual(store.entries[.main]?[1]?.origin, .snapshot)
        XCTAssertTrue(change.tombstoned.isEmpty)
    }

    func testNewChatNeverRemoves() {
        announce(1, main: 5)

        _ = store.applyPositions(newChat(1))
        XCTAssertEqual(ids(.main), [1], "an empty vector only means the lists are not loaded")

        _ = store.applyPositions(newChat(1, folder(7, 3)))
        XCTAssertEqual(ids(.main), [1])
        XCTAssertEqual(ids(.folder(7)), [1])
    }

    func testNewChatIgnoresZeroOrderPositions() {
        _ = store.applyPositions(newChat(1, main(0)))

        XCTAssertNil(store.entries[.main]?[1], "zero order in a chat's vector is not a removal")
        XCTAssertNotNil(store.chat(id: 1, stampedFor: .main), "but the chat itself is known")
    }

    func testPositionEventsStampTheirListsIndependently() {
        announce(1, main: 5, folder7: 90)
        _ = store.applyPositions(explicit(1, folder(7, 95, pinned: true)))

        XCTAssertEqual(store.chats(in: .main).first?.order, 5)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, false)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.order, 95)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.isPinned, true)
    }

    // MARK: - Main and the archive exclude each other

    func testArchivePositionRetiresAMainSnapshot() {
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .restore)

        let change = store.applyPositions(newChat(1, archive(3)))

        XCTAssertEqual(ids(.main), [], "a chat TDLib put in the archive is not in Main")
        XCTAssertEqual(ids(.archive), [1])
        XCTAssertEqual(store.entries[.main]?[1]?.isTombstone, true)
        XCTAssertEqual(change.tombstoned, [.main: [1]])
    }

    func testArchivePositionInAReplacementVectorRetiresAMainSnapshot() {
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .restore)

        _ = store.applyPositions(replacement(1, archive(3)))

        XCTAssertEqual(ids(.main), [])
        XCTAssertEqual(ids(.archive), [1])
    }

    func testMainPositionRetiresTheArchiveEntry() {
        _ = store.applyPositions(newChat(1, archive(3)))

        let change = store.applyPositions(explicit(1, main(8)))

        XCTAssertEqual(ids(.main), [1])
        XCTAssertEqual(ids(.archive), [], "unarchived")
        XCTAssertEqual(change.tombstoned, [.archive: [1]])
    }

    func testArchivePositionKeepsAStalePageFromReturningTheChatToMain() {
        _ = store.applyPositions(newChat(9, archive(3)))

        _ = store.applySnapshot([chat(9, order: 4)], in: .main, mode: .page(since: 0, replacingSnapshots: false))

        XCTAssertEqual(ids(.main), [], "the page predates the move")
    }

    func testFolderPositionLeavesMainAndTheArchiveAlone() {
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .restore)

        _ = store.applyPositions(newChat(1, folder(7, 3)))

        XCTAssertEqual(ids(.main), [1])
        XCTAssertNil(store.entries[.archive]?[1])
    }

    // MARK: - Snapshots

    func testSnapshotCannotOverrideUpdateEntryOrTombstone() {
        announce(1, main: 9)
        announce(2, main: 8)
        _ = store.applyPositions(explicit(2, main(0)))
        let rows = [chat(1, order: 3), chat(2, order: 7)]

        for mode: ChatStore.SnapshotMode in [.restore, .page(since: 0, replacingSnapshots: false)] {
            _ = store.applySnapshot(rows, in: .main, mode: mode)

            XCTAssertEqual(store.chats(in: .main).map(\.order), [9], "\(mode)")
            XCTAssertEqual(ids(.main), [1], "\(mode)")
        }
        _ = store.applySnapshot([chat(2, order: 7)], in: .main, mode: .fetched(since: 0))
        XCTAssertEqual(ids(.main), [1], "a fetched row cannot lift a tombstone either")
    }

    func testPageDoesNotRollBackFieldsChangedAfterItsRequest() {
        _ = store.applySnapshot([chat(1, order: 5, unread: 0)], in: .main, mode: .page(since: 0, replacingSnapshots: false))
        let since = store.revision

        _ = store.updateRecord(1) { $0.unreadCount = 4 }
        _ = store.applyFields(chat(2, unread: 1))
        _ = store.applySnapshot(
            [chat(1, order: 5, unread: 0), chat(2, order: 4, unread: 0)],
            in: .main,
            mode: .page(since: since, replacingSnapshots: false)
        )

        XCTAssertEqual(record(1)?.unreadCount, 4, "the page was requested before the read mark")
        XCTAssertEqual(record(2)?.unreadCount, 1, "and before the field update")
        XCTAssertEqual(ids(.main), [1, 2], "its rows still enter the list")
    }

    func testPageOverwritesFieldsRestoredFromDisk() {
        _ = store.applySnapshot([chat(1, order: 5, title: "Disk", unread: 9)], in: .main, mode: .restore)
        let since = store.revision

        _ = store.applySnapshot(
            [chat(1, order: 6, title: "Server", unread: 0)],
            in: .main,
            mode: .page(since: since, replacingSnapshots: false)
        )

        XCTAssertEqual(record(1)?.title, "Server")
        XCTAssertEqual(record(1)?.unreadCount, 0)
        XCTAssertEqual(store.chats(in: .main).first?.order, 6)
    }

    func testReplacingPageDropsMissingSnapshotsButKeepsUpdateEntries() {
        _ = store.applySnapshot(
            [chat(1, order: 9), chat(2, order: 8), chat(3, order: 7)], in: .main, mode: .restore)
        announce(4, main: 6)

        _ = store.applySnapshot([chat(1, order: 9)], in: .main, mode: .page(since: 0, replacingSnapshots: false))
        XCTAssertEqual(ids(.main), [1, 2, 3, 4])

        let change = store.applySnapshot([chat(1, order: 9)], in: .main, mode: .page(since: 0, replacingSnapshots: true))

        XCTAssertEqual(ids(.main), [1, 4], "chat 4 was reported by TDLib in this session")
        XCTAssertTrue(change.lists.contains(.main))
    }

    func testCompletePrefixPageDropsSnapshotsInsideItsRangeOnly() {
        _ = store.applySnapshot(
            [chat(1, order: 90), chat(2, order: 80), chat(3, order: 70), chat(4, order: 60)], in: .main, mode: .restore)
        let since = store.revision

        let change = store.applySnapshot(
            [chat(1, order: 90), chat(3, order: 70)], in: .main, mode: completePrefix(since: since))

        XCTAssertEqual(ids(.main), [1, 3, 4], "chat 2 ranks inside the page, which lacks it; chat 4 ranks below the page")
        XCTAssertTrue(change.lists.contains(.main))
    }

    func testCompletePrefixPageBreaksTiesByChatId() {
        _ = store.applySnapshot([chat(2, order: 70), chat(9, order: 70)], in: .main, mode: .restore)
        let since = store.revision

        _ = store.applySnapshot([chat(5, order: 70)], in: .main, mode: completePrefix(since: since))

        XCTAssertEqual(ids(.main), [5, 2], "(70, 9) ranks above the page's last row (70, 5), (70, 2) below it")
    }

    func testCompletePrefixPageKeepsUpdateEntries() {
        _ = store.applySnapshot([chat(1, order: 90), chat(3, order: 70)], in: .main, mode: .restore)
        announce(2, main: 80)
        let since = store.revision

        _ = store.applySnapshot([chat(1, order: 90), chat(3, order: 70)], in: .main, mode: completePrefix(since: since))

        XCTAssertEqual(ids(.main), [1, 2, 3], "TDLib reported chat 2 in this session; the page may predate that")
    }

    func testCompletePrefixPageKeepsRowsWrittenAfterItsRequest() {
        _ = store.applySnapshot([chat(1, order: 90), chat(3, order: 70)], in: .main, mode: .restore)
        let since = store.revision

        // A new message made the app fetch chat 2 while the page was on its way.
        _ = store.applySnapshot([chat(2, order: 80)], in: .main, mode: .fetched(since: since))
        _ = store.applySnapshot([chat(1, order: 90), chat(3, order: 70)], in: .main, mode: completePrefix(since: since))

        XCTAssertEqual(ids(.main), [1, 2, 3])
    }

    func testCompletePrefixPageWithoutAKnownRangeDropsNothing() {
        _ = store.applySnapshot([chat(1, order: 90), chat(2, order: 80)], in: .main, mode: .restore)
        let since = store.revision

        _ = store.applySnapshot([], in: .main, mode: completePrefix(since: since))
        XCTAssertEqual(ids(.main), [1, 2], "an empty page has no range")

        _ = store.applySnapshot([chat(3, order: 0)], in: .main, mode: completePrefix(since: since))
        XCTAssertEqual(ids(.main), [1, 2, 3], "a row without an order has no place in the range")
    }

    func testRestoreInsertsMissingRecordsOnly() {
        _ = store.applyFields(chat(1, title: "Fresh"))
        let revision = store.revision

        _ = store.applySnapshot([chat(1, order: 5, title: "Disk"), chat(2, order: 4, title: "Disk 2")], in: .main, mode: .restore)

        XCTAssertEqual(record(1)?.title, "Fresh")
        XCTAssertEqual(record(2)?.title, "Disk 2")
        XCTAssertEqual(ids(.main), [1, 2])
        XCTAssertEqual(store.revision, revision, "reading the disk is not news")
    }

    func testBeginSessionDemotesPositivesAndKeepsTombstones() {
        announce(1, main: 9)
        announce(2, main: 8)
        _ = store.applyPositions(explicit(2, main(0)))

        store.beginSession()

        XCTAssertEqual(store.entries[.main]?[1]?.origin, .snapshot)
        XCTAssertEqual(store.entries[.main]?[1]?.order, 9)
        XCTAssertEqual(store.entries[.main]?[2]?.isTombstone, true)
        // The new client has to confirm membership again: a page may now
        // drop what it no longer returns, and an empty vector removes nothing.
        _ = store.applyPositions(replacement(1))
        XCTAssertEqual(ids(.main), [1])
        _ = store.applySnapshot([], in: .main, mode: .page(since: 0, replacingSnapshots: true))
        XCTAssertEqual(ids(.main), [])
    }

    // MARK: - Projection

    func testProjectionOrdersByOrderThenIdDescending() {
        for (id, order) in [(1, 5), (2, 9), (3, 5), (4, 7)] as [(Int64, Int64)] {
            announce(id, main: order)
        }

        XCTAssertEqual(ids(.main), [2, 4, 3, 1])
    }

    func testProjectionOrdersListsRestoredWithoutPositionsByRowOrder() {
        _ = store.applySnapshot(
            [chat(1, order: 1), chat(2, order: 3), chat(3, order: 2)], in: .folder(7), mode: .restore)

        XCTAssertEqual(ids(.folder(7)), [2, 3, 1])
    }

    func testProjectionTakesPinFromItsOwnList() {
        announce(1, main: 50, folder7: 40)
        _ = store.applyPositions(explicit(1, main(500, pinned: true)))

        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.isPinned, false)
        XCTAssertEqual(store.chat(id: 1, stampedFor: .folder(7))?.isPinned, false)
    }

    func testChatLookupFallsBackToMainThenToUnlisted() {
        announce(1, main: 50)
        _ = store.applyFields(chat(2))

        XCTAssertEqual(store.chat(id: 1, stampedFor: .folder(7))?.order, 50, "not in folder 7: Main's place")
        XCTAssertEqual(store.chat(id: 2, stampedFor: .main)?.order, 0)
        XCTAssertEqual(store.chat(id: 2, stampedFor: .main)?.isPinned, false)
        XCTAssertNil(store.chat(id: 3, stampedFor: .main))
    }

    func testTombstonedChatsAreNotProjectedButStayInTheDirectory() {
        announce(1, main: 50)
        _ = store.applyPositions(explicit(1, main(0)))

        XCTAssertEqual(ids(.main), [])
        XCTAssertNotNil(store.chat(id: 1, stampedFor: .main))
        XCTAssertFalse(store.isListed(1, in: .main))
    }

    // MARK: - Field snapshots

    func testFieldSnapshotNeverRemovesOrReordersUpdateEntries() {
        announce(1, main: 9)

        _ = store.applyFields(chat(1, order: 0, title: "Renamed"))
        _ = store.applyFields(chat(1, order: 3, pinned: true))

        XCTAssertEqual(ids(.main), [1])
        XCTAssertEqual(store.chats(in: .main).first?.order, 9)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, false)
    }

    func testFieldSnapshotRefreshesOnlySnapshotMainOrder() {
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .restore)
        _ = store.applySnapshot([chat(1, order: 5)], in: .folder(7), mode: .restore)

        let change = store.applyFields(chat(1, order: 8, pinned: true))

        XCTAssertEqual(store.chats(in: .main).first?.order, 8)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.order, 5)
        XCTAssertEqual(change.lists, [.main])
        XCTAssertEqual(change.chatIds, [1])
    }

    func testFieldSnapshotWithZeroOrderKeepsASnapshotEntry() {
        _ = store.applySnapshot([chat(1, order: 5, pinned: true)], in: .main, mode: .restore)

        _ = store.applyFields(chat(1, order: 0, title: "Bootstrap"))

        XCTAssertEqual(store.chats(in: .main).first?.order, 5)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)
        XCTAssertEqual(store.chats(in: .main).first?.title, "Bootstrap")
    }

    func testFieldSnapshotThatChangesNothingReportsNoChange() {
        announce(1, main: 5)

        let repeated = store.applyFields(chat(1, order: 5))
        XCTAssertTrue(repeated.isEmpty, "the announcement already brought these fields")

        var edited = chat(1, order: 5)
        edited.lastMessage = message(7, "Before")
        XCTAssertEqual(store.applyFields(edited).chatIds, [1])
        edited.lastMessage = message(7, "After")
        XCTAssertEqual(store.applyFields(edited).chatIds, [1], "same message id, new text")
        XCTAssertTrue(store.applyFields(edited).isEmpty)
    }

    func testFieldSnapshotThatChangesNothingStillStampsTheRecord() {
        _ = store.applyFields(chat(1, title: "Current"))
        let since = store.revision

        _ = store.applyFields(chat(1, title: "Current"))
        _ = store.applySnapshot(
            [chat(1, order: 5, title: "Older")], in: .main, mode: .page(since: since, replacingSnapshots: false))

        XCTAssertEqual(record(1)?.title, "Current", "TDLib confirmed the record after the page was requested")
    }

    func testFieldSnapshotCreatesRecordWithoutEntries() {
        let change = store.applyFields(chat(9, order: 4))

        XCTAssertEqual(record(9)?.id, 9)
        XCTAssertEqual(ids(.main), [])
        XCTAssertTrue(change.lists.isEmpty, "a chat nobody listed changes no list")
        XCTAssertEqual(change.chatIds, [9])
    }

    // MARK: - Fetched and directory rows

    func testFetchedArchivedChatDoesNotEnterMain() {
        _ = store.applySnapshot([chat(1, order: 0)], in: .main, mode: .fetched(since: 0))
        XCTAssertEqual(ids(.main), [], "order 0 in Main: archived or in no list")
        XCTAssertNotNil(record(1))

        _ = store.applySnapshot([chat(2, order: 4)], in: .main, mode: .fetched(since: 0))
        XCTAssertEqual(ids(.main), [2])
        XCTAssertEqual(store.entries[.main]?[2]?.origin, .snapshot)
    }

    func testFetchedRowDoesNotTouchOtherLists() {
        _ = store.applySnapshot([chat(1, order: 4)], in: .folder(7), mode: .fetched(since: 0))

        XCTAssertEqual(ids(.folder(7)), [])
        XCTAssertEqual(ids(.main), [])
    }

    func testDirectoryFetchNeverLists() {
        let change = store.applySnapshot([chat(1, order: 7)], in: .main, mode: .directory(since: 0))

        XCTAssertEqual(store.chat(id: 1, stampedFor: .main)?.id, 1)
        XCTAssertEqual(ids(.main), [])
        XCTAssertTrue(change.lists.isEmpty)
    }

    func testDirectoryFetchDoesNotRollBackNewerFields() {
        _ = store.applyFields(chat(1, title: "Old"))
        let since = store.revision
        _ = store.applyFields(chat(1, title: "Newer"))

        _ = store.applySnapshot([chat(1, title: "Fetched")], in: .main, mode: .directory(since: since))

        XCTAssertEqual(record(1)?.title, "Newer")
    }

    // MARK: - Record updates and overlays

    func testUpdateRecordIgnoresUnknownChat() {
        let change = store.updateRecord(42) { $0.unreadCount = 3 }

        XCTAssertTrue(change.isEmpty)
        XCTAssertNil(store.chat(id: 42, stampedFor: .main))
    }

    func testUpdateRecordChangesAKnownChatEverywhere() {
        announce(1, main: 5, folder7: 4)

        let change = store.updateRecord(1) { $0.unreadCount = 6 }

        XCTAssertEqual(change.chatIds, [1])
        XCTAssertEqual(store.chats(in: .main).first?.unreadCount, 6)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.unreadCount, 6)
    }

    func testPendingPinOverlayHoldsUntilMatchingUpdate() {
        announce(1, main: 5)

        _ = store.setPendingPin(1, in: .main, to: true)
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)

        // A page or a field update still says "not pinned".
        _ = store.applySnapshot([chat(1, order: 5)], in: .main, mode: .page(since: 0, replacingSnapshots: false))
        _ = store.applyFields(chat(1, order: 5))
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true)

        _ = store.applyPositions(explicit(1, main(5, pinned: false)))
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, true, "an update that disagrees is not the answer")

        _ = store.applyPositions(explicit(1, main(900, pinned: true)))
        XCTAssertTrue(store.pendingPins.isEmpty)

        _ = store.applyPositions(explicit(1, main(5, pinned: false)))
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, false)
    }

    func testPendingPinOverlayCanBeCleared() {
        announce(1, main: 5)
        _ = store.setPendingPin(1, in: .main, to: true)

        let change = store.setPendingPin(1, in: .main, to: nil)

        XCTAssertEqual(change.chatIds, [1])
        XCTAssertEqual(store.chats(in: .main).first?.isPinned, false)
        XCTAssertTrue(store.pendingPins.isEmpty)
    }

    func testPendingPinOverlayOnlyAppliesToItsList() {
        announce(1, main: 5, folder7: 4)

        _ = store.setPendingPin(1, in: .folder(7), to: true)

        XCTAssertEqual(store.chats(in: .main).first?.isPinned, false)
        XCTAssertEqual(store.chats(in: .folder(7)).first?.isPinned, true)
    }

    func testPendingMuteOverlayHoldsUntilMatchingSnapshot() {
        announce(1, main: 5)

        _ = store.setPendingMute(1, to: true)
        XCTAssertEqual(store.chats(in: .main).first?.isMuted, true)

        _ = store.applyFields(chat(1, order: 5, muted: false))
        XCTAssertEqual(store.chats(in: .main).first?.isMuted, true, "a snapshot from before the request")

        _ = store.applyFields(chat(1, order: 5, muted: true))
        XCTAssertTrue(store.pendingMutes.isEmpty)
        XCTAssertEqual(store.chats(in: .main).first?.isMuted, true)

        _ = store.applyFields(chat(1, order: 5, muted: false))
        XCTAssertEqual(store.chats(in: .main).first?.isMuted, false)
    }

    func testTypingSurvivesFieldSnapshots() {
        announce(1, main: 5)

        _ = store.setTyping(1, names: ["Ann"], kind: .typing)
        _ = store.applyFields(chat(1, order: 5, title: "Renamed"))

        XCTAssertEqual(store.chats(in: .main).first?.typingUserNames, ["Ann"])
        XCTAssertEqual(store.chats(in: .main).first?.typingActionKind, .typing)
        XCTAssertEqual(store.chats(in: .main).first?.title, "Renamed")

        _ = store.applyPositions(explicit(1, main(6)))

        XCTAssertEqual(store.chat(id: 1, stampedFor: .main)?.typingUserNames, ["Ann"])
    }

    func testTypingCanBeClearedOneAtATimeOrAll() {
        announce(1, main: 5)
        announce(2, main: 4)
        _ = store.setTyping(1, names: ["Ann"], kind: .typing)
        _ = store.setTyping(2, names: ["Bob"], kind: .recordingVoice)

        XCTAssertTrue(store.setTyping(1, names: ["Ann"], kind: .typing).isEmpty, "nothing changed")
        XCTAssertEqual(store.setTyping(1, names: [], kind: .typing).chatIds, [1])
        XCTAssertEqual(store.chats(in: .main).first?.typingUserNames, [])
        XCTAssertEqual(store.chats(in: .main).first?.typingActionKind, ChatActionKind.none)
        XCTAssertEqual(store.chats(in: .main).last?.typingUserNames, ["Bob"])

        XCTAssertEqual(store.clearTyping([2, 3]).chatIds, [2])
        XCTAssertTrue(store.typing.isEmpty)
    }

    // MARK: - Seed

    func testSeedReplacesTheListExactly() {
        announce(1, main: 5)
        announce(2, main: 4)
        _ = store.applyPositions(explicit(2, main(0)))
        var typingRow = chat(3, order: 3)
        typingRow.typingUserNames = ["Ann"]
        typingRow.typingActionKind = .typing

        _ = store.applySnapshot([chat(2, order: 2), typingRow], in: .main, mode: .seed)

        XCTAssertEqual(ids(.main), [3, 2], "the tombstone for chat 2 went with the old entries")
        XCTAssertEqual(store.chats(in: .main).first?.typingUserNames, ["Ann"])
    }

    func testSeedLeavesOtherListsAlone() {
        announce(1, main: 5, folder7: 4)

        _ = store.applySnapshot([], in: .main, mode: .seed)

        XCTAssertEqual(ids(.main), [])
        XCTAssertEqual(ids(.folder(7)), [1])
    }

    func testSeedOverwritesRecords() {
        _ = store.applyFields(chat(1, title: "Old"))

        _ = store.applySnapshot([chat(1, order: 5, title: "Seeded")], in: .main, mode: .seed)

        XCTAssertEqual(record(1)?.title, "Seeded")
    }

    // MARK: - Change

    func testChangeFormUnionMergesEveryPart() {
        var change = ChatStore.Change(lists: [.main], chatIds: [1], tombstoned: [.main: [1]])

        change.formUnion(ChatStore.Change(lists: [.archive], chatIds: [2], tombstoned: [.main: [2], .folder(7): [3]]))

        XCTAssertEqual(change.lists, [.main, .archive])
        XCTAssertEqual(change.chatIds, [1, 2])
        XCTAssertEqual(change.tombstoned, [.main: [1, 2], .folder(7): [3]])
        XCTAssertFalse(change.isEmpty)
        XCTAssertTrue(ChatStore.Change().isEmpty)
    }

    // MARK: - Helpers

    private func chat(
        _ id: Int64, order: Int64 = 0, pinned: Bool = false, title: String? = nil, unread: Int = 0, muted: Bool = false
    ) -> ChatInfo {
        ChatInfo(
            id: id, title: title ?? "Chat \(id)", lastMessage: nil, unreadCount: unread,
            isGroup: false, isMuted: muted, order: order, isPinned: pinned
        )
    }

    private func main(_ order: Int64, pinned: Bool = false) -> ChatListPosition {
        ChatListPosition(list: .main, order: order, isPinned: pinned)
    }

    private func folder(_ id: Int64, _ order: Int64, pinned: Bool = false) -> ChatListPosition {
        ChatListPosition(list: .folder(id), order: order, isPinned: pinned)
    }

    private func message(_ id: Int64, _ text: String) -> MessageInfo {
        MessageInfo(
            id: id, chatId: 1, senderName: "Bob", senderId: 2,
            content: .text(FormattedString(text: text)), date: Date(timeIntervalSince1970: 1), isOutgoing: false, isRead: false
        )
    }

    private func archive(_ order: Int64) -> ChatListPosition {
        ChatListPosition(list: .archive, order: order, isPinned: false)
    }

    private func completePrefix(since: UInt64) -> ChatStore.SnapshotMode {
        .page(since: since, replacingSnapshots: false, isCompletePrefix: true)
    }

    private func explicit(_ id: Int64, _ positions: ChatListPosition...) -> ChatPositionUpdate {
        ChatPositionUpdate(chat: chat(id), positions: positions, source: .explicitPosition)
    }

    private func replacement(_ id: Int64, _ positions: ChatListPosition...) -> ChatPositionUpdate {
        ChatPositionUpdate(chat: chat(id), positions: positions, source: .positionsReplacement)
    }

    private func newChat(_ id: Int64, _ positions: ChatListPosition...) -> ChatPositionUpdate {
        ChatPositionUpdate(chat: chat(id), positions: positions, source: .newChat)
    }

    /// A chat TDLib announced with positions in Main and, optionally, folder 7.
    private func announce(_ id: Int64, main order: Int64, folder7: Int64? = nil) {
        var positions = [main(order)]
        if let folder7 { positions.append(folder(7, folder7)) }
        _ = store.applyPositions(ChatPositionUpdate(chat: chat(id, order: order), positions: positions, source: .newChat))
    }

    private func ids(_ list: ChatListID) -> [Int64] {
        store.chats(in: list).map(\.id)
    }

    private func record(_ id: Int64) -> ChatInfo? {
        store.chat(id: id, stampedFor: .main)
    }
}
