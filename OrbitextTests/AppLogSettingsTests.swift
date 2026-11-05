import XCTest
@testable import OrbitextWatch

final class AppLogSettingsTests: XCTestCase {
    func testDebugKeepsCountersWithoutNativePayloadLogsOrPeriodicDumps() {
        let settings = configuration(isDebug: true)
        XCTAssertTrue(settings.tdTelemetryEnabled)
        XCTAssertFalse(settings.tdTelemetryPeriodicDump)
        XCTAssertFalse(settings.tdTelemetryStack)
        XCTAssertEqual(settings.tdlibVerbosity, 2, "Warnings and errors remain enabled")
    }

    func testReleaseKeepsErrorsWithoutDiagnosticCollectionByDefault() {
        let settings = configuration(isDebug: false)
        XCTAssertFalse(settings.tdTelemetryEnabled)
        XCTAssertFalse(settings.tdTelemetryPeriodicDump)
        XCTAssertEqual(settings.tdlibVerbosity, 1)
    }

    func testTelemetryAndTransportOptInsDoNotEnableNativePayloadLogging() {
        let settings = configuration(
            arguments: ["--td-telemetry", "--td-telemetry-stack", "--verbose-td-transport-logs"],
            isDebug: false
        )
        XCTAssertTrue(settings.tdTelemetryEnabled)
        XCTAssertTrue(settings.tdTelemetryStack)
        XCTAssertTrue(settings.verboseTDTransport)
        XCTAssertFalse(settings.verboseTDInternals)
        XCTAssertFalse(settings.tdTelemetryPeriodicDump)
        XCTAssertEqual(settings.tdlibVerbosity, 1)
    }

    func testNativeInternalLogsRequireTheirOwnExplicitOptIn() {
        for settings in [
            configuration(environment: ["VERBOSE_TD_INTERNAL_LOGS": "1"]),
            configuration(arguments: ["--verbose-td-internal-logs"])
        ] {
            XCTAssertTrue(settings.verboseTDInternals)
            XCTAssertEqual(settings.tdlibVerbosity, 5)
        }
    }

    func testPeriodicOptInEnablesCollectionInRelease() {
        for settings in [
            configuration(environment: ["TD_TELEMETRY_DUMP": "1"], isDebug: false),
            configuration(arguments: ["--td-telemetry-dump"], isDebug: false)
        ] {
            XCTAssertTrue(settings.tdTelemetryEnabled)
            XCTAssertTrue(settings.tdTelemetryPeriodicDump)
            XCTAssertEqual(settings.tdlibVerbosity, 1)
        }
    }

    func testExplicitMasterDisableWinsOverPeriodicOptIn() {
        for settings in [
            configuration(environment: ["TD_TELEMETRY": "0", "TD_TELEMETRY_DUMP": "1"]),
            configuration(arguments: ["--td-telemetry", "--td-telemetry-dump", "--no-td-telemetry"])
        ] {
            XCTAssertFalse(settings.tdTelemetryEnabled)
            XCTAssertFalse(settings.tdTelemetryPeriodicDump)
        }
    }

    func testExplicitCollectionArgumentPreservesEnvironmentOverridePrecedence() {
        let settings = configuration(
            environment: ["TD_TELEMETRY": "0"],
            arguments: ["--td-telemetry"]
        )
        XCTAssertTrue(settings.tdTelemetryEnabled)
        XCTAssertFalse(settings.tdTelemetryPeriodicDump)
    }

    private func configuration(
        environment: [String: String] = [:],
        arguments: [String] = [],
        isDebug: Bool = true
    ) -> AppLogSettings.Configuration {
        AppLogSettings.Configuration(environment: environment, arguments: arguments, isDebug: isDebug)
    }
}
