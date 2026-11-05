import XCTest

/// Explicitly selected checks around a normal, signed simulator launch.
/// The runner never launches the app or changes its authentication state.
@MainActor
final class LiveLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["ORBITEXT_LIVE_QA"] == "1",
              ProcessInfo.processInfo.environment["ORBITEXT_LIVE_QA_LIFECYCLE"] == "1" else {
            throw XCTSkip("Live lifecycle checks require both runner opt-ins.")
        }
    }

    func testColdChatListKeepsSavedMessagesVisible() async throws {
        let app = try existingSelfChatList()
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(app.navigationBars["Chats"].exists)
            XCTAssertTrue(app.buttons["saved-messages-row"].firstMatch.isHittable,
                          "The authenticated self-chat row disappeared while the initial updates settled.")
        }
    }

    func testMoveExistingAppToBackground() throws {
        let app = try existingSelfChatList()
        guard XCUIDevice.shared.hasHardwareButton(.home) else {
            throw XCTSkip("This simulator does not expose the Home button through XCTest.")
        }
        XCUIDevice.shared.press(.home)
        let background = NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: background, object: nil)], timeout: 15),
            .completed,
            "The existing application did not enter the background."
        )
    }

    func testExistingAppIsInBackground() {
        // The host can normally open the installed Settings with simctl when
        // watchOS Simulator does not expose a Home button through XCTest.
        let app = XCUIApplication(bundleIdentifier: "com.orbitext.app.watchkitapp")
        let background = NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: background, object: nil)], timeout: 10),
            .completed,
            "The observed application is not running in the background."
        )
    }

    private func existingSelfChatList() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.orbitext.app.watchkitapp")
        guard app.state == .runningForeground else {
            throw XCTSkip("Normally launch the authenticated app before running this check.")
        }
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["saved-messages-row"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["saved-messages-row"].firstMatch.isHittable)
        return app
    }
}
