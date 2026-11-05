import XCTest

/// Opt-in regression coverage against an already open authenticated session.
/// Only navigation and selecting the already active All Chats folder are used.
@MainActor
final class LiveRootNavigationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["ORBITEXT_LIVE_QA"] == "1" else {
            throw XCTSkip("Live navigation requires an explicit test-runner opt-in.")
        }
    }

    func testSettingsContactsAndSearchReturnToChatList() throws {
        let app = try existingChatList()
        for (control, title) in [("Settings", "Settings"), ("Contacts", "Contacts"), ("Search messages", "Search")] {
            try tapUnique(app.buttons.matching(identifier: control), name: control)
            try requireTitle(title, in: app)
            try returnToChats(in: app)
        }
    }

    func testAllChatsFolderCanBeReopenedWithoutChangingSelection() throws {
        let app = try existingChatList()
        try tapUnique(app.buttons.matching(identifier: "Folder: All Chats"), name: "current All Chats folder")
        try requireTitle("Folder", in: app)
        try tapUnique(app.buttons.matching(identifier: "All Chats"), name: "All Chats folder option")
        try requireTitle("Chats", in: app)
        XCTAssertTrue(app.buttons["Folder: All Chats"].waitForExistence(timeout: 10))
    }

    /// Opt-in, read-only workload for comparing the same signed-in simulator
    /// before and after a performance change. Never enters or marks a chat read.
    func testChatListScrollPerformance() throws {
        let app = try existingChatList()
        try scrollToListControls(in: app)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            // Carousel inertia can leave different rows visible after equal
            // numbers of up/down gestures. Normalize outside the measurement.
            do { try scrollToListControls(in: app) } catch { return }
            startMeasuring()
            for _ in 0..<3 { dragList(in: app, upward: true) }
            for _ in 0..<3 { dragList(in: app, upward: false) }
        }
        try requireTitle("Chats", in: app)
        try scrollToListControls(in: app)
    }

    private func scrollToListControls(in app: XCUIApplication) throws {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Folder:")).firstMatch
        for _ in 0..<10 {
            if folder.exists && folder.isHittable { return }
            dragList(in: app, upward: false)
        }
        guard folder.exists && folder.isHittable else {
            XCTFail("Could not return to the chat-list controls after scrolling")
            throw NavigationFailure.unexpectedState
        }
    }

    private func dragList(in app: XCUIApplication, upward: Bool) {
        // Whole-app swipeDown starts inside the fixed watch navigation header,
        // where it never reaches the list. Keep both endpoints in its viewport.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let start = upward ? lower : upper
        let end = upward ? upper : lower
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    }

    private func existingChatList() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.orbitext.app.watchkitapp")
        guard app.state == .runningForeground else {
            throw XCTSkip("The normally launched app must already be in the foreground.")
        }
        try requireTitle("Chats", in: app)
        return app
    }

    private func returnToChats(in app: XCUIApplication) throws {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Chats"))
        try tapUnique(back, name: "back to Chats")
        try requireTitle("Chats", in: app)
    }

    private func tapUnique(_ query: XCUIElementQuery, name: String) throws {
        let exists = query.firstMatch.waitForExistence(timeout: 10)
        let visible = query.allElementsBoundByIndex.filter(\.isHittable).map { ($0, $0.frame) }
            .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        // The toolbar image and expanded hit region have the same ID and exact
        // common center on watchOS 27. Different target centers still fail.
        guard exists, let first = visible.first, !first.1.isEmpty,
              visible.allSatisfy({ !$0.1.isEmpty && $0.1.midX == first.1.midX && $0.1.midY == first.1.midY }) else {
            let states = query.allElementsBoundByIndex.map { "hittable=\($0.isHittable), frame=\($0.frame)" }
            XCTFail("Missing, ambiguous or inaccessible \(name): exists=\(exists), count=\(query.count), states=\(states).")
            throw NavigationFailure.unexpectedState
        }
        first.0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func requireTitle(_ title: String, in app: XCUIApplication) throws {
        let predicate = NSPredicate { _, _ in
            app.navigationBars[title].exists || app.staticTexts[title].firstMatch.exists
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10) == .completed else {
            XCTFail("Expected \(title) screen.")
            throw NavigationFailure.unexpectedState
        }
    }

    private enum NavigationFailure: Error { case unexpectedState }
}
