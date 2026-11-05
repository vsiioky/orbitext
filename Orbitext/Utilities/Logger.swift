import Foundation
import os

enum AppLogSettings {
    private static let configuration: Configuration = {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return Configuration(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            isDebug: isDebug
        )
    }()

    static let verboseTDInternals = configuration.verboseTDInternals
    static let verboseTDTransport = configuration.verboseTDTransport
    static let tdlibVerbosity = configuration.tdlibVerbosity

    /// In-memory counters remain enabled in DEBUG for manual export. They never
    /// raise native verbosity or start a periodic console dump on their own.
    static let tdTelemetryEnabled = configuration.tdTelemetryEnabled

    /// Explicit opt-in: TD_TELEMETRY_DUMP=1 or --td-telemetry-dump.
    static let tdTelemetryPeriodicDump = configuration.tdTelemetryPeriodicDump

    /// When true, telemetry captures up to 15 callstack frames per send.
    /// Adds 50-100us per record; enable only for diagnostic sessions.
    /// Override via env `TD_TELEMETRY_STACK=1` or launch arg `--td-telemetry-stack`.
    static let tdTelemetryStack = configuration.tdTelemetryStack

    struct Configuration {
        let verboseTDInternals: Bool
        let verboseTDTransport: Bool
        let tdlibVerbosity: Int
        let tdTelemetryEnabled: Bool
        let tdTelemetryPeriodicDump: Bool
        let tdTelemetryStack: Bool

        init(environment: [String: String], arguments: [String], isDebug: Bool) {
            verboseTDInternals = environment["VERBOSE_TD_INTERNAL_LOGS"] == "1" ||
                arguments.contains("--verbose-td-internal-logs")
            verboseTDTransport = environment["VERBOSE_TD_TRANSPORT_LOGS"] == "1" ||
                arguments.contains("--verbose-td-transport-logs")
            // Native info/debug output can contain request payloads and credentials.
            // Only the explicit internal-log switch may enable those levels.
            tdlibVerbosity = verboseTDInternals ? 5 : (isDebug ? 2 : 1)

            let periodicRequested = environment["TD_TELEMETRY_DUMP"] == "1" ||
                arguments.contains("--td-telemetry-dump")
            if arguments.contains("--no-td-telemetry") {
                tdTelemetryEnabled = false
            } else if arguments.contains("--td-telemetry") {
                tdTelemetryEnabled = true
            } else if let value = environment["TD_TELEMETRY"] {
                tdTelemetryEnabled = value == "1"
            } else {
                tdTelemetryEnabled = isDebug || periodicRequested
            }
            tdTelemetryPeriodicDump = tdTelemetryEnabled && periodicRequested
            tdTelemetryStack = environment["TD_TELEMETRY_STACK"] == "1" ||
                arguments.contains("--td-telemetry-stack")
        }
    }
}

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.orbitext"

    static let tdlib = Logger(subsystem: subsystem, category: "TDLib")
    static let app = Logger(subsystem: subsystem, category: "App")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let network = Logger(subsystem: subsystem, category: "Network")
}
