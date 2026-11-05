import XCTest
@testable import OrbitextWatch

final class SharedPlaybackFilesTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID().uuidString)")
        directory = root.appendingPathComponent(SharedPlaybackFiles.directoryName, isDirectory: true)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        directory = nil
        sources = nil
        super.tearDown()
    }

    func testCopyRunsOnTheQueueNotOnTheCaller() async throws {
        let queue = DispatchQueue(label: "SharedPlaybackFilesTests.copy")
        let files = makeFiles(queue: queue)
        let source = try makeSource(Self.mp4Header + Data("video".utf8))
        queue.suspend()

        let copy = Task { await files.copy(source, fileId: "7") }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "The copy ran on the caller's thread")
        queue.resume()
        let result = await copy.value
        let copied = try XCTUnwrap(result)
        XCTAssertEqual(copied.lastPathComponent, "7.mp4")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The source belongs to the transport")
    }

    func testCopyIsNamedAfterTheContainerItsBytesHold() async throws {
        let files = makeFiles()
        var quickTime = Self.mp4Header
        quickTime.replaceSubrange(8..<12, with: Data("qt  ".utf8))
        let source = try makeSource(quickTime, name: "clip.mp4")

        let copied = await files.copy(source, fileId: "a/b")

        XCTAssertEqual(copied?.lastPathComponent, "a_b.mov")
    }

    func testWriteIsNamedAfterTheContainerItsBytesHold() async throws {
        let files = makeFiles()
        let matroska = Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(repeating: 0, count: 12)

        let written = await files.write(matroska, fileId: "9")

        let url = try XCTUnwrap(written)
        XCTAssertEqual(url.lastPathComponent, "9.mkv")
        XCTAssertEqual(try Data(contentsOf: url), matroska)
    }

    func testRemovalIssuedBeforeACopyLeavesTheCopy() async throws {
        let files = makeFiles()
        let source = try makeSource(Self.mp4Header)
        _ = await files.copy(source, fileId: "5")

        files.remove(fileId: "5")
        let result = await files.copy(source, fileId: "5")
        let copied = try XCTUnwrap(result)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testRemoveAndClearDeleteTheCopies() async throws {
        let files = makeFiles()
        let source = try makeSource(Self.mp4Header)
        let firstResult = await files.copy(source, fileId: "1")
        let first = try XCTUnwrap(firstResult)

        files.remove(fileId: "1")
        _ = await files.write(Data(), fileId: "barrier")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        let secondResult = await files.copy(source, fileId: "2")
        let second = try XCTUnwrap(secondResult)
        files.clear()
        _ = await files.copy(source, fileId: "3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    /// Only one player is open at a time, and file ids mean nothing after a
    /// relaunch, so the copy of an earlier video is nobody's: without this,
    /// every video opened stays in the app group until Clear cache.
    func testCopyReplacesTheCopyOfAnEarlierVideo() async throws {
        let files = makeFiles()
        let source = try makeSource(Self.mp4Header + Data("video".utf8))
        let earlier = await files.copy(source, fileId: "1")
        let earlierWrite = await files.write(Self.mp4Header, fileId: "2")

        let latest = await files.copy(source, fileId: "3")

        XCTAssertNotNil(earlier)
        XCTAssertNotNil(earlierWrite)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, try [XCTUnwrap(latest).lastPathComponent], "Copies of earlier videos stay on the watch")
    }

    func testWriteReplacesTheCopyOfAnEarlierVideo() async throws {
        let files = makeFiles()
        let earlier = await files.write(Self.mp4Header, fileId: "1")

        let latest = await files.write(Self.mp4Header + Data("video".utf8), fileId: "2")

        XCTAssertNotNil(earlier)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, try [XCTUnwrap(latest).lastPathComponent])
    }

    func testReopeningTheSameVideoKeepsItsOneCopy() async throws {
        let files = makeFiles()
        let source = try makeSource(Self.mp4Header + Data("video".utf8))

        let first = await files.copy(source, fileId: "1")
        let second = await files.copy(source, fileId: "1")

        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testNoAppGroupContainerMeansNoCopy() async throws {
        let files = SharedPlaybackFiles(directory: { nil })
        let source = try makeSource(Self.mp4Header)

        let copied = await files.copy(source, fileId: "1")
        let written = await files.write(Self.mp4Header, fileId: "2")

        XCTAssertNil(copied)
        XCTAssertNil(written)
    }

    // MARK: - Helpers

    /// An MP4 `ftyp` box with the isom brand.
    private static let mp4Header = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 4)

    private func makeFiles(queue: DispatchQueue = DispatchQueue(label: "SharedPlaybackFilesTests")) -> SharedPlaybackFiles {
        let directory = directory!
        return SharedPlaybackFiles(directory: { directory }, queue: queue)
    }

    private func makeSource(_ data: Data, name: String = "source-\(UUID().uuidString).bin") throws -> URL {
        let url = sources.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
