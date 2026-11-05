import os
import SwiftUI

struct VoiceRecorderView: View {
    private struct PendingRecording {
        let url: URL
        let duration: Int
    }

    @Environment(VoiceManager.self) private var voiceManager
    @Environment(MessageManager.self) private var messageManager
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64

    @State private var isSending = false
    @State private var isVisible = false
    @State private var failedRecording: PendingRecording?

    var body: some View {
        VStack(spacing: 10) {
            if isSending {
                ProgressView()
            } else if let failedRecording {
                Image(systemName: "exclamationmark.waveform")
                    .font(.system(size: 32))
                    .foregroundStyle(WristTheme.Palette.danger)

                Text(formatTime(TimeInterval(failedRecording.duration)))
                    .font(.title3.monospacedDigit())

                HStack(spacing: 12) {
                    Button {
                        discardFailedRecording()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(WristTheme.Palette.primaryText)
                            .frame(width: 44, height: 44)
                            .background(WristGlassBackground(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Cancel voice recording"))

                    Button {
                        Task { await sendRecording(failedRecording) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)
                            .foregroundStyle(WristTheme.Palette.voice)
                            .frame(width: 52, height: 52)
                            .background(WristGlassBackground(cornerRadius: 26, tint: WristTheme.Palette.voice))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Tap to retry"))
                }
            } else if voiceManager.isRecording {
                Image(systemName: "waveform")
                    .font(.system(size: 32))
                    .foregroundStyle(WristTheme.Palette.voice)
                    .symbolEffect(.pulse, isActive: true)

                Text(formatTime(voiceManager.recordingDuration))
                    .font(.title3.monospacedDigit())

                HStack(spacing: 12) {
                    Button {
                        voiceManager.cancelRecording()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(WristTheme.Palette.primaryText)
                            .frame(width: 44, height: 44)
                            .background(WristGlassBackground(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Cancel voice recording"))

                    Button {
                        Task { await stopAndSend() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .foregroundStyle(WristTheme.Palette.voice)
                            .frame(width: 52, height: 52)
                            .background(WristGlassBackground(cornerRadius: 26, tint: WristTheme.Palette.voice))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Send voice message"))
                }
            } else {
                Button {
                    voiceManager.startRecording()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(WristTheme.Palette.accent)
                        .frame(width: 76, height: 76)
                        .background(WristGlassBackground(cornerRadius: 38, tint: WristTheme.Palette.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Start voice recording"))
            }
        }
        .padding(10)
        .background(WristGlassBackground())
        .padding(.horizontal, 8)
        .navigationTitle(L10n.string("Voice"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WristScreenBackground() }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            voiceManager.cancelRecording()
            if failedRecording != nil, !isSending {
                discardFailedRecording()
            }
        }
    }

    private func stopAndSend() async {
        guard let (url, duration) = voiceManager.stopRecording() else { return }
        await sendRecording(PendingRecording(url: url, duration: duration))
    }

    private func sendRecording(_ recording: PendingRecording) async {
        isSending = true
        defer { isSending = false }
        do {
            let data = try await Self.loadVoiceData(from: recording.url)
            let sent = await messageManager.sendVoice(chatId: chatId, data: data, duration: recording.duration)
            if sent {
                removeRecordingFile(recording.url)
                failedRecording = nil
                if isVisible { dismiss() }
            } else if isVisible {
                failedRecording = recording
            } else {
                removeRecordingFile(recording.url)
            }
        } catch {
            Logger.app.error("Failed to read recorded voice file: \(error.localizedDescription, privacy: .public)")
            if isVisible {
                failedRecording = recording
            } else {
                removeRecordingFile(recording.url)
            }
        }
    }

    private func discardFailedRecording() {
        guard let failedRecording else { return }
        removeRecordingFile(failedRecording.url)
        self.failedRecording = nil
    }

    private func removeRecordingFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.app.warning("Failed to remove voice recording file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads a finished recording off the main actor: a synchronous read of a
    /// long recording would freeze the spinner that is showing meanwhile.
    nonisolated static func loadVoiceData(
        from url: URL,
        read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try read(url)
        }.value
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        TimeFormatting.duration(seconds)
    }
}
