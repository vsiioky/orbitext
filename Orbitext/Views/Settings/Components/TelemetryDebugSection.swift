import os
import SwiftUI

#if DEBUG
/// Phase 1 diagnostic section. Renders only when a telemetry actor is
/// present (i.e. AppLogSettings.tdTelemetryEnabled is true). Tapping the
/// button emits the markdown dump to os_log so Console.app captures it
/// for export. watchOS has no UIPasteboard, so the log channel is the
/// only practical export surface.
struct TelemetryDebugSection: View {
    let telemetry: TDRequestTelemetry?
    @State private var lastExportSize: Int?
    @State private var isExporting = false

    var body: some View {
        if let telemetry {
            Section("Diagnostics") {
                Button {
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        let dump = await telemetry.dump()
                        Logger.network.notice("TDTelemetry export (manual):\n\(dump, privacy: .public)")
                        await MainActor.run {
                            lastExportSize = dump.count
                            isExporting = false
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export TDLib trace")
                            .font(.caption)
                        if let s = lastExportSize {
                            Text("\(s) chars logged")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Writes to Console (subsystem Network)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isExporting)
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }
        }
    }
}
#endif
