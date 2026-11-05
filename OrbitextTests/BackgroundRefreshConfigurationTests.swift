import XCTest
@testable import OrbitextWatch

@MainActor
final class BackgroundRefreshConfigurationTests: XCTestCase {
    func testBuiltWatchAppAdvertisesNamedRefreshHandler() {
        // This checks the packaged configuration; the operating system deciding
        // to register and execute the handler is a separate device check.
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "WKApplication") as? Bool, true)
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
            [BackgroundRefreshScheduler.taskIdentifier]
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
            ["remote-notification"]
        )
    }
}
