import XCTest
@testable import OrbitextWatch

@MainActor
final class VoiceRecordingLoadTests: XCTestCase {
    func testRecordingIsReadOffTheMainThread() async throws {
        let recording = try makeRecording(Data("recorded audio".utf8))
        defer { try? FileManager.default.removeItem(at: recording) }
        let readThread = ReadThreadProbe()

        // The test itself runs on the main actor, like the recorder screen.
        XCTAssertTrue(Thread.isMainThread)
        let data = try await VoiceRecorderView.loadVoiceData(from: recording) { url in
            readThread.record(isMain: Thread.isMainThread)
            return try Data(contentsOf: url)
        }

        XCTAssertEqual(data, Data("recorded audio".utf8))
        XCTAssertEqual(readThread.readOnMainThread, false, "Reading the recording blocked the main thread")
    }

    func testMissingRecordingThrowsInsteadOfSendingNothing() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).m4a")

        do {
            _ = try await VoiceRecorderView.loadVoiceData(from: missing)
            XCTFail("A recording that cannot be read must not become an empty voice message")
        } catch {
            // Expected: the screen keeps the recording so the user can retry.
        }
    }

    private func makeRecording(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        try data.write(to: url)
        return url
    }
}

private final class ReadThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var readOnMainThread: Bool? { lock.withLock { stored } }
    func record(isMain: Bool) { lock.withLock { stored = isMain } }
}
