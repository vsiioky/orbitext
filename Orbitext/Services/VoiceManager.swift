import AVFoundation
import MediaPlayer
import Observation
import os

@MainActor
@Observable
final class VoiceManager: NSObject {
    enum VoiceState: Equatable {
        case idle
        case recording(duration: TimeInterval)
        case playing(fileId: String?, progress: Double)
        case paused(fileId: String?, progress: Double)

        static func == (lhs: VoiceState, rhs: VoiceState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.recording(let a), .recording(let b)): return a == b
            case (.playing(let a1, let a2), .playing(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.paused(let a1, let a2), .paused(let b1, let b2)): return a1 == b1 && a2 == b2
            default: return false
            }
        }
    }

    private(set) var state: VoiceState = .idle

    var isRecording: Bool { if case .recording = state { true } else { false } }
    var isPlaying: Bool { if case .playing = state { true } else { false } }
    var recordingDuration: TimeInterval { if case .recording(let d) = state { d } else { 0 } }
    var playbackProgress: Double {
        switch state {
        case .playing(_, let progress), .paused(_, let progress): progress
        default: 0
        }
    }
    var currentlyPlayingFileId: String? {
        switch state {
        case .playing(let fileId, _), .paused(let fileId, _): fileId
        default: nil
        }
    }

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var recordingURL: URL?
    private var audioSessionActive = false
    private var recordingPermissionRequestID: UUID?
    private var pendingPlaybackRequestID: UUID?
    nonisolated deinit {}

    static let recordingsDir: URL = {
        let dir = FileManager.appSupportDirectory
            .appendingPathComponent("recordings", isDirectory: true)
        AudioSessionHelper.ensureDirectory(at: dir)
        return dir
    }()

    // MARK: - Recording

    func startRecording() {
        pendingPlaybackRequestID = nil
        if case .paused = state { stop() }
        guard case .idle = state else { return }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecordingAfterPermission()
        case .undetermined:
            requestRecordPermission()
        case .denied:
            Logger.app.error("Microphone permission denied")
        @unknown default:
            Logger.app.error("Unknown microphone permission state")
        }
    }

    private func requestRecordPermission() {
        guard let requestID = beginRecordingPermissionRequest() else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.consumeRecordingPermissionRequest(requestID) else { return }
                guard granted else {
                    Logger.app.error("Microphone permission denied")
                    return
                }
                self.startRecordingAfterPermission()
            }
        }
    }

    /// Request identity prevents a delayed permission reply from starting a
    /// recording after navigation, or consuming a newer recorder's request.
    func beginRecordingPermissionRequest() -> UUID? {
        guard recordingPermissionRequestID == nil else { return nil }
        let requestID = UUID()
        recordingPermissionRequestID = requestID
        return requestID
    }

    func consumeRecordingPermissionRequest(_ requestID: UUID) -> Bool {
        guard recordingPermissionRequestID == requestID else { return false }
        recordingPermissionRequestID = nil
        return true
    }

    private func startRecordingAfterPermission() {
        guard case .idle = state else { return }
        // .duckOthers lowers other apps' audio while recording.
        // Note: .allowBluetooth / .allowBluetoothHFP require watchOS 11+; on
        // watchOS 10 the system routes paired Bluetooth input automatically
        // for AVAudioSessionCategory.playAndRecord, so no flag is required.
        guard AudioSessionHelper.activate(
            category: .playAndRecord,
            options: [.duckOthers]
        ) else { return }
        audioSessionActive = true
        let url = Self.recordingsDir.appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder?.record() == true else {
                Logger.app.error("AVAudioRecorder.record() returned false")
                recorder = nil
                deactivateSession()
                return
            }
            recordingURL = url
            state = .recording(duration: 0)

            recordingTimer = AudioSessionHelper.startPeriodicTimer(interval: 0.25) { [weak self] in
                guard let self, case .recording = self.state else { return }
                self.state = .recording(duration: self.recorder?.currentTime ?? 0)
            }
            HapticManager.recording()
        } catch {
            Logger.app.error("AVAudioRecorder init failed: \(error.localizedDescription, privacy: .public)")
            deactivateSession()
        }
    }

    func stopRecording() -> (URL, Int)? {
        guard case .recording(let duration) = state else { return nil }
        AudioSessionHelper.stopTimer(&recordingTimer)
        recorder?.stop()
        state = .idle
        deactivateSession()
        HapticManager.recordingStopped()
        guard let url = recordingURL else { return nil }
        recordingURL = nil
        return (url, max(1, Int(duration)))
    }

    func cancelRecording() {
        // Permission can still be pending while state is .idle.
        recordingPermissionRequestID = nil
        guard case .recording = state else { return }
        AudioSessionHelper.stopTimer(&recordingTimer)
        recorder?.stop()
        state = .idle
        deactivateSession()

        if let url = recordingURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Logger.app.warning("Failed to remove cancelled recording: \(error.localizedDescription, privacy: .public)")
            }
            recordingURL = nil
        }
    }

    // MARK: - Playback

    /// Only the latest requested message may start after its download finishes.
    func requestPlayback() -> UUID {
        let requestID = UUID()
        pendingPlaybackRequestID = requestID
        return requestID
    }

    func isPlaybackRequestCurrent(_ requestID: UUID) -> Bool {
        pendingPlaybackRequestID == requestID
    }

    func cancelPlaybackRequest(_ requestID: UUID) {
        guard isPlaybackRequestCurrent(requestID) else { return }
        pendingPlaybackRequestID = nil
    }

    func consumePlaybackRequest(_ requestID: UUID) -> Bool {
        guard isPlaybackRequestCurrent(requestID) else { return false }
        pendingPlaybackRequestID = nil
        return true
    }

    func isPlaying(fileId: String) -> Bool {
        if case .playing(let fid, _) = state { return fid == fileId }
        return false
    }

    func isPaused(fileId: String) -> Bool {
        if case .paused(let fid, _) = state { return fid == fileId }
        return false
    }

    @discardableResult
    func play(data: Data, fileId: String? = nil) -> Bool {
        stop()
        guard !data.isEmpty else { return false }
        // .duckOthers lowers music/podcast volume from other apps while playing
        // a voice message.
        guard AudioSessionHelper.activate(
            category: .playback,
            options: [.duckOthers]
        ) else { return false }
        audioSessionActive = true

        // The player reads the bytes it is given. The transport hands them
        // over memory-mapped from its own file, so a play writes no file and
        // copies nothing. The player finds the format (Ogg Opus, M4A, MP3,
        // WAV) from the bytes, not from a file name.
        do {
            let player = try AVAudioPlayer(data: data)
            guard player.prepareToPlay() else {
                deactivateSession()
                return false
            }
            self.player = player
        } catch {
            Logger.app.error("Playback setup failed: \(error.localizedDescription, privacy: .public)")
            deactivateSession()
            return false
        }

        player?.delegate = self
        guard player?.play() == true else {
            teardownPlayback(stopPlayer: false)
            return false
        }
        state = .playing(fileId: fileId, progress: 0)
        setupNowPlaying(duration: player?.duration ?? 0)
        startPlaybackTimer()
        return true
    }

    func pause() {
        pendingPlaybackRequestID = nil
        guard case .playing(let fileId, _) = state, let player else { return }
        player.pause()
        AudioSessionHelper.stopTimer(&playbackTimer)
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        state = .paused(fileId: fileId, progress: progress)
        updateNowPlaying(elapsedTime: player.currentTime, rate: 0)
        deactivateSession()
    }

    @discardableResult
    func resume() -> Bool {
        guard case .paused(let fileId, _) = state, let player else { return false }
        pendingPlaybackRequestID = nil
        guard AudioSessionHelper.activate(category: .playback, options: [.duckOthers]) else { return false }
        audioSessionActive = true
        guard player.play() else {
            deactivateSession()
            return false
        }
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        state = .playing(fileId: fileId, progress: progress)
        updateNowPlaying(elapsedTime: player.currentTime, rate: 1)
        startPlaybackTimer()
        return true
    }

    func stop() {
        pendingPlaybackRequestID = nil
        teardownPlayback(stopPlayer: true)
    }

    func cleanup() {
        // Stop playback first.
        stop()
        // If a recording is in progress, abort and discard it before we
        // wipe the recordings directory. Without this, AVAudioRecorder
        // continues to write to a file whose parent we just removed -
        // its subsequent stop() call would silently fail and we would
        // leak the orphan recorder + activated audio session.
        cancelRecording()
        AudioSessionHelper.removeAndRecreateDirectory(Self.recordingsDir)
    }

    /// Deletes the copies earlier versions wrote to tmp for each play, as
    /// <UUID>.ogg, .m4a, .mp3 or .wav. A process that died while playing
    /// left its copy behind, and nothing removed it. Off the main actor, at
    /// launch, before anything plays.
    nonisolated static func removePlaybackCopiesOfEarlierRuns(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where earlierPlaybackCopyExtensions.contains(file.pathExtension)
            && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Logger.app.warning("Failed to remove an old playback copy: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated static let earlierPlaybackCopyExtensions: Set = ["ogg", "m4a", "mp3", "wav"]

    // MARK: - Private

    private func teardownPlayback(stopPlayer: Bool, matchingPlayerID expectedPlayerID: ObjectIdentifier? = nil) {
        if let expectedPlayerID {
            guard let currentPlayer = player, ObjectIdentifier(currentPlayer) == expectedPlayerID else { return }
        }
        AudioSessionHelper.stopTimer(&playbackTimer)
        if stopPlayer { player?.stop() }
        player = nil
        switch state {
        case .playing, .paused: state = .idle
        default: break
        }
        clearNowPlaying()
        deactivateSession()
    }

    private func startPlaybackTimer() {
        AudioSessionHelper.stopTimer(&playbackTimer)
        playbackTimer = AudioSessionHelper.startPeriodicTimer(interval: 0.2) { [weak self] in
            guard let self, let player = self.player, case .playing(let fileId, _) = self.state else { return }
            let progress = player.duration > 0 ? player.currentTime / player.duration : 0
            self.state = .playing(fileId: fileId, progress: progress)
            self.updateNowPlaying(elapsedTime: player.currentTime, rate: 1)
        }
    }

    private func setupNowPlaying(duration: TimeInterval) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Voice message",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    private func clearNowPlaying() { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }

    private func updateNowPlaying(elapsedTime: TimeInterval, rate: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
    }

    private func deactivateSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        AudioSessionHelper.deactivate()
    }
}

extension VoiceManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            self.teardownPlayback(stopPlayer: false, matchingPlayerID: playerID)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            self.teardownPlayback(stopPlayer: false, matchingPlayerID: playerID)
        }
    }
}
