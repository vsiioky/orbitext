import XCTest

/// Runs only against the operator's already-running, English-language session.
/// This target never imports the app module or supplies a launch environment.
@MainActor
final class LiveSavedMessagesSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["ORBITEXT_LIVE_QA"] == "1" else {
            throw XCTSkip("Set ORBITEXT_LIVE_QA=1 in the test runner to opt into live navigation QA.")
        }
    }

    func testExistingSavedMessagesReadOnlyNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.orbitext.app.watchkitapp")
        guard app.state == .runningForeground else {
            // activate() could launch a process that stops after a state check.
            // Only observe the app the operator already left in the foreground.
            throw XCTSkip("Open the normally signed app and leave its authenticated Chats screen visible first.")
        }
        try require(app.wait(for: .runningForeground, timeout: 10), "Existing app did not become active.")
        let alreadyOpen = app.navigationBars["Saved Messages"].exists &&
            app.textFields["Reply"].firstMatch.isHittable
        if !alreadyOpen {
            try requireTitle("Chats", in: app)
            // Resolve the account-owned self chat independently of its title.
            let savedMessages = try singleHittable(
                app.buttons.matching(identifier: "saved-messages-row"),
                named: "Saved Messages row"
            )
            savedMessages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        try requireSavedMessagesControls(in: app)

        try singleHittable(app.buttons.matching(identifier: "Attach"), named: "Attach control").tap()
        try requireTitle("Attach", in: app)
        // Opening the picker is enough; no voice, sticker or location action.
        try goBack(from: "Attach", to: "Saved Messages", in: app)
        try requireSavedMessagesControls(in: app)

        try singleHittable(app.buttons.matching(identifier: "saved-messages-profile"), named: "Profile control").tap()
        try requireTitle("Profile", in: app)
        try goBack(from: "Profile", to: "Saved Messages", in: app)
        try requireSavedMessagesControls(in: app)
        try goBack(from: "Saved Messages", to: "Chats", in: app)

        try singleHittable(app.buttons.matching(identifier: "Settings"), named: "Settings control").tap()
        try requireTitle("Settings", in: app)
        // Do not tap account, storage, notification, or other setting controls.
        try goBack(from: "Settings", to: "Chats", in: app)
    }

    private func requireSavedMessagesControls(in app: XCUIApplication) throws {
        try requireTitle("Saved Messages", in: app)
        _ = try singleHittable(app.textFields.matching(identifier: "Reply"), named: "Reply field")
        _ = try singleHittable(app.buttons.matching(identifier: "Attach"), named: "Attach control")
        _ = try singleHittable(app.buttons.matching(identifier: "saved-messages-profile"), named: "Profile control")
    }

    private func requireTitle(_ title: String, in app: XCUIApplication) throws {
        let visible = NSPredicate { _, _ in
            let bar = app.navigationBars[title]
            let text = app.staticTexts[title].firstMatch
            return bar.exists || (text.exists && text.isHittable)
        }
        let expectation = XCTNSPredicateExpectation(predicate: visible, object: nil)
        try require(
            XCTWaiter.wait(for: [expectation], timeout: 10) == .completed,
            "Expected the \(title) screen. Live QA stops on an unexpected route or authentication screen."
        )
    }

    private func singleHittable(_ query: XCUIElementQuery, named name: String) throws -> XCUIElement {
        try require(query.firstMatch.waitForExistence(timeout: 10), "Missing \(name).")
        var resolved: XCUIElement?
        let uniqueGeometry = NSPredicate { _, _ in
            // Sample each frame once. Initial history layout can move the bar
            // between AX reads; wait for coincident aliases instead of guessing.
            let visible = query.allElementsBoundByIndex.filter(\.isHittable).map { ($0, $0.frame) }
                .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            guard let first = visible.first, !first.1.isEmpty,
                  visible.allSatisfy({ !$0.1.isEmpty && $0.1.midX == first.1.midX && $0.1.midY == first.1.midY }) else { return false }
            resolved = first.0
            return true
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: uniqueGeometry, object: nil)], timeout: 5)
        try require(result == .completed, "Ambiguous or inaccessible \(name); no action taken.")
        return try XCTUnwrap(resolved)
    }

    private func goBack(from currentTitle: String, to previousTitle: String, in app: XCUIApplication) throws {
        try requireTitle(currentTitle, in: app)
        let back = app.navigationBars.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "Back", previousTitle
        ))
        try singleHittable(back, named: "navigation back control").tap()
        try requireTitle(previousTitle, in: app)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw SmokeFailure.unexpectedState
        }
    }

    private enum SmokeFailure: Error { case unexpectedState }
}
