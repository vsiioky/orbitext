import AVFoundation
import os

/// Encapsulates AVAudioSession activation/deactivation and periodic timer management
/// used by VoiceManager for both recording and playback.
enum AudioSessionHelper {
    /// Activate the audio session with the given category, mode and options.
    /// Returns `true` on success.
    ///
    /// Common option choices (watchOS 10 deployment target):
    ///   .playAndRecord (recording) -> [.duckOthers]
    ///     lower other audio. Bluetooth input routing is system-managed on
    ///     watchOS 10; .allowBluetooth / .allowBluetoothHFP are watchOS 11+.
    ///   .playback                  -> [.duckOthers]
    ///     lower other audio (music, podcasts) during playback
    @discardableResult
    static func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode = .default,
        options: AVAudioSession.CategoryOptions = []
    ) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(true)
            return true
        } catch {
            Logger.app.error("AudioSession activate failed (category=\(category.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Deactivate the audio session, notifying others.
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.app.warning("AudioSession deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Periodic Timer

    /// Creates a repeating timer that fires on the main actor.
    /// The caller receives the timer reference for later invalidation.
    @MainActor
    static func startPeriodicTimer(
        interval: TimeInterval = 0.1,
        action: @escaping @Sendable @MainActor () -> Void
    ) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
    }

    /// Invalidate and nil-out a timer reference.
    @MainActor
    static func stopTimer(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Directory Helpers

    /// Create a directory if it doesn't exist, logging failures.
    static func ensureDirectory(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Logger.app.error("Failed to create directory \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove a directory and recreate it empty, logging failures.
    static func removeAndRecreateDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.app.warning("Failed to remove directory \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Logger.app.error("Failed to recreate directory \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
