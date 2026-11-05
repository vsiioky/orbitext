import MediaPlayer
import XCTest
import zlib
@testable import OrbitextWatch

@MainActor
final class VoiceManagerTests: XCTestCase {
    func testInitialStateIsIdle() {
        let manager = VoiceManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isRecording)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.recordingDuration, 0)
        XCTAssertEqual(manager.playbackProgress, 0)
        XCTAssertNil(manager.currentlyPlayingFileId)
    }

    func testStopFromIdleIsNoOp() {
        let manager = VoiceManager()
        manager.stop()
        XCTAssertEqual(manager.state, .idle)
    }

    func testCancelRecordingFromIdleIsNoOp() {
        let manager = VoiceManager()
        manager.cancelRecording()
        XCTAssertEqual(manager.state, .idle)
    }

    func testStopRecordingFromIdleReturnsNil() {
        let manager = VoiceManager()
        XCTAssertNil(manager.stopRecording())
    }

    func testCancelledPendingPermissionCannotStartRecording() throws {
        let manager = VoiceManager()
        let requestID = try XCTUnwrap(manager.beginRecordingPermissionRequest())
        XCTAssertEqual(manager.state, .idle, "Permission request does not itself start recording")

        manager.cancelRecording()

        XCTAssertFalse(manager.consumeRecordingPermissionRequest(requestID))
        XCTAssertEqual(manager.state, .idle)
    }

    func testOldPermissionReplyCannotConsumeNewRequestAfterReopen() throws {
        let manager = VoiceManager()
        let oldRequest = try XCTUnwrap(manager.beginRecordingPermissionRequest())
        manager.cancelRecording()
        let newRequest = try XCTUnwrap(manager.beginRecordingPermissionRequest())

        XCTAssertNotEqual(newRequest, oldRequest)
        XCTAssertFalse(manager.consumeRecordingPermissionRequest(oldRequest))
        XCTAssertTrue(manager.consumeRecordingPermissionRequest(newRequest))
    }

    func testPermissionRequestIsSingleFlightAndReplyIsConsumedOnlyOnce() throws {
        let manager = VoiceManager()
        let requestID = try XCTUnwrap(manager.beginRecordingPermissionRequest())

        XCTAssertNil(manager.beginRecordingPermissionRequest())
        XCTAssertTrue(manager.consumeRecordingPermissionRequest(requestID))
        XCTAssertFalse(manager.consumeRecordingPermissionRequest(requestID))
        XCTAssertNotNil(manager.beginRecordingPermissionRequest())
        manager.cancelRecording()
    }

    func testIsPlayingFileIdReturnsFalseWhenIdle() {
        let manager = VoiceManager()
        XCTAssertFalse(manager.isPlaying(fileId: "test"))
    }

    func testConvenienceAccessorsInIdleState() {
        let manager = VoiceManager()
        XCTAssertFalse(manager.isRecording)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.recordingDuration, 0)
        XCTAssertEqual(manager.playbackProgress, 0)
        XCTAssertNil(manager.currentlyPlayingFileId)
    }

    func testPauseAndResumeFromIdleAreNoOps() {
        let manager = VoiceManager()

        manager.pause()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isPaused(fileId: "voice"))
        XCTAssertFalse(manager.resume())
    }

    func testOnlyLatestPendingPlaybackCanBeConsumed() {
        let manager = VoiceManager()
        let first = manager.requestPlayback()
        let second = manager.requestPlayback()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(manager.isPlaybackRequestCurrent(first))
        XCTAssertFalse(manager.consumePlaybackRequest(first))
        XCTAssertTrue(manager.isPlaybackRequestCurrent(second))
        XCTAssertTrue(manager.consumePlaybackRequest(second))
        XCTAssertFalse(manager.consumePlaybackRequest(second))
    }

    func testStaleCancellationPreservesNewerPlaybackRequest() {
        let manager = VoiceManager()
        let first = manager.requestPlayback()
        let second = manager.requestPlayback()

        manager.cancelPlaybackRequest(first)

        XCTAssertTrue(manager.isPlaybackRequestCurrent(second))
        manager.cancelPlaybackRequest(second)
        XCTAssertFalse(manager.consumePlaybackRequest(second))
    }

    func testStopAndPauseCancelPendingPlaybackWhileIdle() {
        let manager = VoiceManager()
        let stoppedRequest = manager.requestPlayback()
        manager.stop()
        XCTAssertFalse(manager.consumePlaybackRequest(stoppedRequest))

        let pausedRequest = manager.requestPlayback()
        manager.pause()
        XCTAssertFalse(manager.consumePlaybackRequest(pausedRequest))
    }

    func testPauseRetainsPlaybackPositionAndResumeContinuesFromIt() async throws {
        let manager = VoiceManager()
        defer { manager.stop() }
        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "voice"))
        try await waitForProgress(manager, above: 0.08)

        manager.pause()
        let pausedProgress = manager.playbackProgress
        XCTAssertTrue(manager.isPaused(fileId: "voice"))
        XCTAssertFalse(manager.isPaused(fileId: "another-voice"))
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.isPlaying(fileId: "voice"))
        XCTAssertEqual(manager.currentlyPlayingFileId, "voice")
        XCTAssertEqual(manager.state, .paused(fileId: "voice", progress: pausedProgress))
        XCTAssertEqual(nowPlayingRate, 0)
        let pausedTime = try XCTUnwrap(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        )
        XCTAssertEqual(pausedTime, pausedProgress * 5, accuracy: 0.01)

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(manager.playbackProgress, pausedProgress, "Paused playback must not advance")
        manager.pause()
        XCTAssertEqual(manager.playbackProgress, pausedProgress, "Pausing twice must preserve the position")

        let supersededRequest = manager.requestPlayback()
        XCTAssertTrue(manager.resume())
        XCTAssertFalse(manager.consumePlaybackRequest(supersededRequest))
        XCTAssertTrue(manager.isPlaying(fileId: "voice"))
        XCTAssertEqual(nowPlayingRate, 1)
        XCTAssertFalse(manager.resume(), "Resuming an already playing message must not restart it")
        // A second pause reads AVAudioPlayer.currentTime, proving that the player
        // itself retained the position rather than only the published state.
        manager.pause()
        XCTAssertEqual(manager.playbackProgress, pausedProgress, accuracy: 0.02)

        XCTAssertTrue(manager.resume())
        try await waitForProgress(manager, above: pausedProgress + 0.02)
    }

    func testStopDiscardsPausedPlayback() {
        let manager = VoiceManager()
        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "voice"))
        manager.pause()

        manager.stop()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(manager.playbackProgress, 0)
        XCTAssertNil(manager.currentlyPlayingFileId)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(manager.resume())
    }

    func testCleanupDiscardsPausedPlayback() {
        let manager = VoiceManager()
        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "voice"))
        manager.pause()

        manager.cleanup()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.currentlyPlayingFileId)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(manager.resume())
    }

    func testPlayingAnotherMessageReplacesPausedPlayback() {
        let manager = VoiceManager()
        defer { manager.stop() }
        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "first"))
        manager.pause()
        let supersededRequest = manager.requestPlayback()

        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "second"))

        XCTAssertFalse(manager.consumePlaybackRequest(supersededRequest))
        XCTAssertTrue(manager.isPlaying(fileId: "second"))
        XCTAssertFalse(manager.isPaused(fileId: "first"))
        XCTAssertEqual(manager.currentlyPlayingFileId, "second")
        XCTAssertEqual(manager.playbackProgress, 0)
        XCTAssertEqual(nowPlayingRate, 1)
    }

    // MARK: - Files

    func testPlaybackWritesNoCopyOfTheAudio() throws {
        let temporary = FileManager.default.temporaryDirectory
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: temporary.path))
        let manager = VoiceManager()
        defer { manager.stop() }

        XCTAssertTrue(manager.play(data: Self.silentWAV(), fileId: "voice"))

        let written = try Set(FileManager.default.contentsOfDirectory(atPath: temporary.path)).subtracting(before)
        XCTAssertEqual(written, [], "Every play wrote the whole file again; the player reads the bytes it is given")
        manager.pause()
        XCTAssertTrue(manager.resume(), "A paused message resumes from the same bytes")
    }

    func testLaunchCleanupRemovesTheAudioCopiesEarlierRunsLeftBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Earlier versions copied each played file to tmp/<UUID>.<ext>; a
        // process killed while playing left its copy there.
        let stale = try ["ogg", "m4a", "mp3", "wav"].map { try makeFile("\(UUID().uuidString).\($0)", in: directory) }
        let unrelated = try ["notes.m4a", "\(UUID().uuidString).mp4", "download-\(UUID().uuidString).bin"]
            .map { try makeFile($0, in: directory) }

        VoiceManager.removePlaybackCopiesOfEarlierRuns(in: directory)

        for url in stale {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) stays in tmp")
        }
        for url in unrelated {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is not a playback copy")
        }
    }

    private func makeFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    private var nowPlayingRate: Double? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double
    }

    private func waitForProgress(_ manager: VoiceManager, above minimum: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while manager.playbackProgress <= minimum && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(manager.playbackProgress, minimum)
    }

    /// Five seconds of mono 16-bit PCM silence exercises the real audio player
    /// without a bundled fixture or audible output from the test suite.
    static func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let byteCount = sampleRate * 5 * 2
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2)) // Block alignment
        append(UInt16(16)) // Bits per sample
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }
}

final class LottieRendererTGSDecompressionTests: XCTestCase {
    func testRenderFrameRejectsInvalidFrameIndicesBeforeCallingRLottie() throws {
        let renderer = try XCTUnwrap(LottieRenderer(json: Self.minimalLottieJSON))

        XCTAssertNil(renderer.renderFrame(at: -1))
        XCTAssertNil(renderer.renderFrame(at: renderer.frameCount))
    }

    func testRenderFramesRejectsNonPositiveStep() throws {
        let renderer = try XCTUnwrap(LottieRenderer(json: Self.minimalLottieJSON))

        XCTAssertEqual(renderer.renderFrames(step: 0, cancel: { false }).count, 0)
        XCTAssertEqual(renderer.renderFrames(step: -1, cancel: { false }).count, 0)
    }

    func testDecodeTGSJSONRejectsFilesAboveTelegramTGSSizeLimit() {
        var data = Data([0x1F, 0x8B])
        data.append(Data(repeating: 0, count: 64 * 1024 - data.count + 1))

        XCTAssertNil(LottieRenderer.decodeTGSJSON(data))
    }

    func testDecodeTGSJSONHandlesHighCompressionRatioGzip() throws {
        let json = #"{"v":"5.7.4","fr":30,"ip":0,"op":1,"w":64,"h":64,"nm":""# +
            String(repeating: " ", count: 40_000) +
            #","ddd":0,"assets":[],"layers":[]}"#
        let compressed = try XCTUnwrap(gzip(Data(json.utf8)))

        XCTAssertLessThan(compressed.count * 100, json.utf8.count)
        XCTAssertEqual(LottieRenderer.decodeTGSJSON(compressed), json)
    }

    private func gzip(_ data: Data) -> Data? {
        var output = Data()
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_STREAM_ERROR
            }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
            stream.avail_in = uInt(data.count)

            // 15 + 16 writes a gzip wrapper around deflate data.
            guard deflateInit2_(
                &stream,
                Z_BEST_COMPRESSION,
                Z_DEFLATED,
                15 + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                return Z_STREAM_ERROR
            }
            defer { deflateEnd(&stream) }

            let chunkSize = 16 * 1024
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = deflate(&stream, Z_FINISH)

                    let produced = buffer.count - Int(stream.avail_out)
                    if produced > 0, let baseAddress = buffer.baseAddress {
                        output.append(baseAddress, count: produced)
                    }
                }

                if status != Z_OK && status != Z_STREAM_END {
                    return status
                }
            }
            return status
        }

        return status == Z_STREAM_END ? output : nil
    }

    private static let minimalLottieJSON = """
    {"v":"5.7.4","fr":30,"ip":0,"op":1,"w":64,"h":64,"nm":"test","ddd":0,"assets":[],"layers":[]}
    """
}
