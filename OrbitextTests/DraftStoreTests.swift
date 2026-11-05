import XCTest
@testable import OrbitextWatch

final class DraftStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    func testGetSetDraft() {
        let store = makeStore()
        store.clearAll()

        store.setDraft(chatId: 1, text: "Hello")
        XCTAssertEqual(store.getDraft(chatId: 1), "Hello")
    }

    func testSetNilClearsDraft() {
        let store = makeStore()
        store.clearAll()

        store.setDraft(chatId: 1, text: "Draft")
        store.setDraft(chatId: 1, text: nil)
        XCTAssertNil(store.getDraft(chatId: 1))
    }

    func testSetEmptyClearsDraft() {
        let store = makeStore()
        store.clearAll()

        store.setDraft(chatId: 1, text: "Draft")
        store.setDraft(chatId: 1, text: "")
        XCTAssertNil(store.getDraft(chatId: 1))
    }

    func testClearAll() {
        let store = makeStore()
        store.setDraft(chatId: 1, text: "A")
        store.setDraft(chatId: 2, text: "B")
        store.clearAll()

        XCTAssertNil(store.getDraft(chatId: 1))
        XCTAssertNil(store.getDraft(chatId: 2))
        XCTAssertTrue(store.allDrafts().isEmpty)
    }

    func testAllDrafts() {
        let store = makeStore()
        store.clearAll()

        store.setDraft(chatId: 1, text: "A")
        store.setDraft(chatId: 2, text: "B")
        let all = store.allDrafts()

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1], "A")
        XCTAssertEqual(all[2], "B")
    }

    func testOverwriteDraft() {
        let store = makeStore()
        store.clearAll()

        store.setDraft(chatId: 1, text: "First")
        store.setDraft(chatId: 1, text: "Second")
        XCTAssertEqual(store.getDraft(chatId: 1), "Second")
    }

    func testSetDraftPersistsBeforeCoalescingDelay() {
        let fileURL = makeTempDir().appendingPathComponent("drafts.json")
        let store = DraftStore(fileURL: fileURL)
        store.clearAll()

        store.setDraft(chatId: 9_004, text: "Immediate")

        let reloaded = DraftStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.getDraft(chatId: 9_004), "Immediate")
    }

    func testCorruptStoreIsPreservedBeforeNewWrites() throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("drafts.json")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: fileURL)

        let store = DraftStore(fileURL: fileURL)

        XCTAssertTrue(store.allDrafts().isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("drafts.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        store.setDraft(chatId: 42, text: "after corruption")

        XCTAssertEqual(store.getDraft(chatId: 42), "after corruption")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)
    }

    func testLoadsExistingStringKeyedDraftsAndKeepsOnDiskFormat() throws {
        let fileURL = makeTempDir().appendingPathComponent("drafts.json")
        let fixture = Data(#"{"-100123":"Group draft","9223372036854775807":"Large ID","invalid":"Ignore"}"#.utf8)
        try fixture.write(to: fileURL)

        let store = DraftStore(fileURL: fileURL)

        XCTAssertEqual(store.allDrafts(), [-100123: "Group draft", Int64.max: "Large ID"])
        store.setDraft(chatId: 42, text: "New draft")

        let persisted = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(persisted, ["-100123": "Group draft", String(Int64.max): "Large ID", "42": "New draft"])
    }

    func testFirstWriteCreatesNestedDirectory() {
        let fileURL = makeTempDir().appendingPathComponent("nested/store/drafts.json")
        let store = DraftStore(fileURL: fileURL)

        XCTAssertTrue(store.allDrafts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        store.setDraft(chatId: 42, text: "Saved immediately")

        XCTAssertEqual(DraftStore(fileURL: fileURL).getDraft(chatId: 42), "Saved immediately")
    }

    func testReadFailureDoesNotMoveExistingDirectoryAsCorruptFile() throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("drafts.json", isDirectory: true)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        let store = DraftStore(fileURL: fileURL)

        XCTAssertTrue(store.allDrafts().isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.map(\.lastPathComponent), ["drafts.json"])
    }

    func testFailedWriteKeepsInMemoryDraftAndExistingFile() throws {
        let blocker = makeTempDir().appendingPathComponent("not-a-directory")
        let original = Data("keep this file".utf8)
        try original.write(to: blocker)
        let store = DraftStore(fileURL: blocker.appendingPathComponent("drafts.json"))

        store.setDraft(chatId: 42, text: "Still editable")

        XCTAssertEqual(store.getDraft(chatId: 42), "Still editable")
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    func testConcurrentDraftWritesPersistAllEntries() {
        let fileURL = makeTempDir().appendingPathComponent("drafts.json")
        let store = DraftStore(fileURL: fileURL)

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            store.setDraft(chatId: Int64(index), text: "Draft \(index)")
        }

        let expected = Dictionary(uniqueKeysWithValues: (0..<20).map { (Int64($0), "Draft \($0)") })
        XCTAssertEqual(store.allDrafts(), expected)
        XCTAssertEqual(DraftStore(fileURL: fileURL).allDrafts(), expected)
    }

    private func makeStore() -> DraftStore {
        DraftStore(fileURL: makeTempDir().appendingPathComponent("drafts.json"))
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
