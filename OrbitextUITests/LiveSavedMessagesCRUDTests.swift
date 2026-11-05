import XCTest

/// Opt-in, English UI, already-running account session. Every editable message
/// belongs to this run in the app-identified self chat. Missing keyboard/status
/// accessibility stops the test; it must be verified on the target runtime.
@MainActor
final class LiveSavedMessagesCRUDTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["ORBITEXT_LIVE_QA"] == "1",
              environment["ORBITEXT_LIVE_QA_SEND"] == "1" else {
            throw XCTSkip("Saved Messages mutations require both live QA runner opt-ins.")
        }
    }

    func testOwnTextReplyEditAndDeleteInSavedMessages() throws {
        try runScenario(run: UUID().uuidString)
    }

    private func runScenario(run: String) throws {
        let app = XCUIApplication(bundleIdentifier: "com.orbitext.app.watchkitapp")
        try requireForeground(app)
        let text = "Тест Orbitext QA \(run)-TEXT"
        let reply = "Тест Orbitext QA \(run)-REPLY"
        let edited = "Тест Orbitext QA \(run)-EDITED"
        let allowlist: Set<String> = [text, reply, edited]
        let record = XCTAttachment(string: "Run: \(run)\nTEXT: \(text)\nREPLY: \(reply)\nEDITED: \(edited)")
        record.name = "Generated QA messages only"
        record.lifetime = .keepAlways
        add(record)

        try enterSelfChat(in: app)
        try requireSelfChat(in: app)
        let composer = try singleHittable(app.textFields.matching(identifier: "Reply"), name: "chat composer")
        try requireEmptyDraft(composer)
        for candidate in allowlist {
            try require(!primaryBubbles(candidate, in: app).firstMatch.exists, "A run message already exists; stop before sending.")
        }

        phase("send-text", run: run)
        try requireSelfChat(in: app)
        try enterTextAndFinish(text, replacing: "", in: composer, completion: "Send", app: app)
        try requireSelfChat(in: app)
        _ = try deliveredBubble(text, in: app)
        try requireEmptyDraft(singleHittable(app.textFields.matching(identifier: "Reply"), name: "chat composer"))

        phase("reply", run: run)
        try openActions(for: text, allowlist: allowlist, in: app)
        try singleHittable(app.buttons.matching(identifier: "Reply"), name: "message Reply action").tap()
        try requireScreen("Reply", in: app)
        // ComposeTarget captures the exact self-chat message selected above.
        // The profile button is on the previous route, so require that captured
        // reply's exact preview before editing the new route's empty draft.
        _ = try singleHittable(app.staticTexts.matching(NSPredicate(format: "label == %@", text)), name: "our reply preview")
        let replyField = try singleHittable(app.textFields.matching(identifier: "Message"), name: "reply composer")
        try requireEmptyDraft(replyField)
        try enterTextAndFinish(reply, replacing: "", in: replyField, completion: "Send", app: app)
        // Native Send invokes .onSubmit. Do not also tap the app's Send message.
        try requireSelfChat(in: app)
        _ = try deliveredBubble(reply, in: app)

        phase("edit-reply", run: run)
        try openActions(for: reply, allowlist: allowlist, in: app)
        try singleHittable(app.buttons.matching(identifier: "Edit"), name: "message Edit action").tap()
        let editField = try singleHittable(app.textFields.matching(identifier: "Edit message"), name: "edit field")
        try requireValue(reply, in: editField, message: "Edit must contain exactly our reply before replacement.")
        try enterTextAndFinish(edited, replacing: reply, in: editField, completion: "Done", app: app)
        try saveEditAndDelete(text: text, reply: reply, edited: edited, allowlist: allowlist, run: run, app: app)
    }

    private func saveEditAndDelete(text: String, reply: String, edited: String, allowlist: Set<String>, run: String, app: XCUIApplication) throws {
        // The native editor's Done changes the field; only this Save edits it.
        let updatedEditField = try singleHittable(app.textFields.matching(identifier: "Edit message"), name: "updated edit field")
        try requireValue(edited, in: updatedEditField, message: "Edit contents do not match our replacement.")
        try singleHittable(app.buttons.matching(identifier: "Save"), name: "Save our edit").tap()
        try requireSelfChat(in: app)
        _ = try deliveredBubble(edited, in: app)
        try requireAbsent(reply, in: app)

        phase("delete-edited-reply", run: run)
        try deleteOwnMessage(edited, allowlist: allowlist, in: app)
        phase("remaining-original-visible-without-scrolling", run: run)
        try requireSelfChat(in: app)
        try waitUntil("Deleting the latest row left the surviving message outside the viewport.") {
            self.primaryBubbles(text, in: app).allElementsBoundByIndex.contains(where: \.isHittable)
        }
        phase("delete-original", run: run)
        try deleteOwnMessage(text, allowlist: allowlist, in: app)
        try requireEmptyDraft(singleHittable(app.textFields.matching(identifier: "Reply"), name: "chat composer"))

        try verifyCleanup(allowlist: allowlist, run: run, app: app)
    }

    private func verifyCleanup(allowlist: Set<String>, run: String, app: XCUIApplication) throws {
        // Re-enter the same app-identified self chat to recheck the loaded
        // history. No generic-prefix cleanup or automatic failure cleanup.
        phase("reopen-and-verify", run: run)
        try requireSelfChat(in: app)
        try singleHittable(app.navigationBars.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "Back", "Chats"
        )), name: "back to Chats").tap()
        try requireScreen("Chats", in: app)
        try enterSelfChat(in: app)
        // ChatView hides this field until its initial history load completes.
        try requireEmptyDraft(singleHittable(app.textFields.matching(identifier: "Reply"), name: "reloaded chat composer"))
        for candidate in allowlist { try requireAbsent(candidate, in: app) }
        phase("complete", run: run)
    }

    private func enterSelfChat(in app: XCUIApplication) throws {
        try requireForeground(app)
        if app.buttons.matching(identifier: "saved-messages-profile").allElementsBoundByIndex.contains(where: \.isHittable) {
            try requireSelfChat(in: app)
            return
        }
        try requireScreen("Chats", in: app)
        try singleHittable(app.buttons.matching(identifier: "saved-messages-row"), name: "genuine self-chat row").tap()
        try requireSelfChat(in: app)
    }

    private func requireSelfChat(in app: XCUIApplication) throws {
        try requireForeground(app)
        _ = try singleHittable(app.buttons.matching(identifier: "saved-messages-profile"), name: "genuine self-chat identity")
        try require(!app.buttons.matching(identifier: "chat-profile").allElementsBoundByIndex.contains(where: \.isHittable),
                    "A different chat is visible; stop.")
    }

    private func requireEmptyDraft(_ field: XCUIElement) throws {
        guard let value = field.value as? String else {
            try require(false, "Draft value is unavailable; stop before typing.")
            return
        }
        // XCUITest can represent an empty field by its placeholder. The native
        // editor must additionally expose a literally empty value before typing.
        try require(value.isEmpty || value == field.placeholderValue, "Existing draft found; it must not be overwritten.")
    }

    private func enterTextAndFinish(
        _ text: String, replacing previous: String, in field: XCUIElement,
        completion: String, app: XCUIApplication
    ) throws {
        try requireForeground(app)
        try require(!text.contains("\n") && !text.contains("\r"), "Submission text must have no return characters.")
        field.tap()
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Native keyboard is unavailable; no text entered.")
        try finishNativeText(text, replacing: previous, completion: completion, app: app)
    }

    private func finishNativeText(_ text: String, replacing previous: String, completion: String, app: XCUIApplication) throws {
        try requireForeground(app)
        try require(!text.contains("\n") && !text.contains("\r"), "No newline submissions.")
        try require(app.keyboards.firstMatch.exists, "Native keyboard required before typing.")
        let editor = try keyboardEditor(containing: previous, in: app)
        if !previous.isEmpty {
            // Deletion is allowed only after exact equality with our own text.
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            try requireValue("", in: editor, message: "Our edit field was not cleared; stop before replacement.")
        }
        editor.typeText(text)
        try requireValue(text, in: editor, message: "Native input does not exactly match the generated text.")
        try requireForeground(app)
        try require(app.keyboards.firstMatch.exists, "Keyboard route changed before completion; do not submit.")
        // Only one explicit completion control. Never send a newline as well,
        // tap the app's Send message afterward, or retry an uncertain send.
        try singleHittable(app.buttons.matching(identifier: completion), name: "native editor completion").tap()
        try waitUntil("Native editor did not close; do not repeat completion.") { !app.keyboards.firstMatch.exists }
    }

    private func keyboardEditor(containing expected: String, in app: XCUIApplication) throws -> XCUIElement {
        var resolved: XCUIElement?
        try waitUntil("Native editable value is unavailable, nonempty or ambiguous; stop before typing.") {
            let fields = app.textFields.allElementsBoundByIndex + app.textViews.allElementsBoundByIndex
            let matching = fields.filter { $0.isHittable && ($0.value as? String) == expected }
                .map { ($0, $0.frame) }.sorted { $0.1.width > $1.1.width }
            guard let first = matching.first, !first.1.isEmpty else { return false }
            // Native watch input exposes both the padded text view and its
            // container: same exact value, vertical bounds and right edge.
            // Live geometry proved 12.5pt inset; the outer view exposes a
            // literal empty value, whereas the inner alias exposes placeholder.
            guard matching.allSatisfy({ !$0.1.isEmpty && $0.1.minY == first.1.minY &&
                $0.1.height == first.1.height && $0.1.maxX == first.1.maxX && first.1.contains($0.1) }) else { return false }
            resolved = first.0
            return true
        }
        return try XCTUnwrap(resolved)
    }

    private func openActions(for text: String, allowlist: Set<String>, in app: XCUIApplication) throws {
        try require(allowlist.contains(text), "Message is outside this run's exact allowlist.")
        try requireSelfChat(in: app)
        let bubble = try deliveredBubble(text, in: app)
        try requireSelfChat(in: app)
        bubble.press(forDuration: 1)
        try require(app.staticTexts["Message"].waitForExistence(timeout: 10), "The exact message actions did not open.")
        _ = try singleHittable(app.buttons.matching(identifier: "Reply"), name: "message actions Reply")
    }

    private func deleteOwnMessage(_ text: String, allowlist: Set<String>, in app: XCUIApplication) throws {
        try openActions(for: text, allowlist: allowlist, in: app)
        // MessageRow Delete acts immediately; it has no second confirmation.
        let delete = app.buttons.matching(identifier: "Delete")
        for _ in 0..<5 {
            if delete.allElementsBoundByIndex.contains(where: \.isHittable) { break }
            try require(app.staticTexts["Message"].exists, "Message actions changed before deleting our message.")
            app.swipeUp()
        }
        try singleHittable(delete, name: "Delete our exact message").tap()
        try requireSelfChat(in: app)
        try requireAbsent(text, in: app)
    }

    private func deliveredBubble(_ text: String, in app: XCUIApplication) throws -> XCUIElement {
        let query = primaryBubbles(text, in: app)
        try require(query.firstMatch.waitForExistence(timeout: 30), "Our outgoing message did not appear; never resend.")
        // Only seek an exact known bubble in this self chat, at most four swipes.
        for _ in 0..<4 {
            if query.allElementsBoundByIndex.contains(where: \.isHittable) { break }
            try requireSelfChat(in: app)
            app.swipeDown()
        }
        let bubble = try singleHittable(query, name: "our exact outgoing message")
        try waitUntil("Delivery status for our exact message is not exposed or not confirmed; never resend.", timeout: 30) {
            guard let status = bubble.value as? String else { return false }
            return ["Sent", "Read", "Failed"].contains(status)
        }
        try require(["Sent", "Read"].contains(bubble.value as? String ?? ""),
                    "Our message failed or its delivery became uncertain; never resend.")
        return bubble
    }

    private func primaryBubbles(_ text: String, in app: XCUIApplication) -> XCUIElementQuery {
        // Full combined MessageRow label; excludes raw text, reply quotations,
        // chat previews and the separate locally queued-message presentation.
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: \(text)"))
    }

    private func requireAbsent(_ text: String, in app: XCUIApplication) throws {
        try waitUntil("Our exact outgoing message is still present; stop without another deletion.", timeout: 30) {
            !self.primaryBubbles(text, in: app).firstMatch.exists
        }
    }

    private func requireValue(_ value: String, in field: XCUIElement, message: String) throws {
        try waitUntil(message) { (field.value as? String) == value }
    }

    private func requireScreen(_ title: String, in app: XCUIApplication) throws {
        try requireForeground(app)
        try waitUntil("Expected navigation screen is unavailable.") { app.navigationBars[title].exists }
    }

    private func singleHittable(_ query: XCUIElementQuery, name: String) throws -> XCUIElement {
        var resolved: XCUIElement?
        try waitUntil("Missing, ambiguous or inaccessible \(name); no action taken.") {
            let visible = query.allElementsBoundByIndex.filter(\.isHittable).map { ($0, $0.frame) }
                .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            guard let first = visible.first, !first.1.isEmpty,
                  visible.allSatisfy({ !$0.1.isEmpty && $0.1.midX == first.1.midX && $0.1.midY == first.1.midY }) else { return false }
            // watchOS exposes both the 37pt toolbar image and its 57pt hit
            // region with the same ID. Their exact common center is one target.
            resolved = first.0
            return true
        }
        return try XCTUnwrap(resolved)
    }

    private func requireForeground(_ app: XCUIApplication) throws {
        try require(app.state == .runningForeground, "Existing app must stay in the foreground; never launch it from this test.")
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed, message)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw LiveQAError.unexpectedState
        }
    }

    private func phase(_ name: String, run: String) {
        XCTContext.runActivity(named: "Saved Messages QA phase=\(name) run=\(run)") { _ in }
    }

    private enum LiveQAError: Error { case unexpectedState }
}
