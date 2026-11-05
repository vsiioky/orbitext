import XCTest
@testable import OrbitextWatch

@MainActor
final class ErrorPresenterTests: XCTestCase {
    func testShowSetsErrorMessage() {
        let presenter = ErrorPresenter()
        presenter.show("Something went wrong", dismissAfter: 10)
        XCTAssertEqual(presenter.error, "Something went wrong")
    }

    func testDismissClearsError() {
        let presenter = ErrorPresenter()
        presenter.show("Error", dismissAfter: 10)
        presenter.dismiss()
        XCTAssertNil(presenter.error)
    }

    func testShowReplacesExistingError() {
        let presenter = ErrorPresenter()
        presenter.show("First", dismissAfter: 10)
        presenter.show("Second", dismissAfter: 10)
        XCTAssertEqual(presenter.error, "Second")
    }

    func testSessionRevokedErrorIsSuppressed() {
        let presenter = ErrorPresenter()
        presenter.show(TDError.api(code: 401, message: "SESSION_REVOKED"))
        XCTAssertNil(presenter.error, "Session revoked errors should be suppressed")
    }

    func testAuthKeyUnregisteredIsSuppressed() {
        let presenter = ErrorPresenter()
        presenter.show(TDError.api(code: 401, message: "AUTH_KEY_UNREGISTERED"))
        XCTAssertNil(presenter.error, "Auth key unregistered should be suppressed")
    }

    func testFloodWaitShowsFormattedMessage() {
        let presenter = ErrorPresenter()
        presenter.show(TDError.api(code: 420, message: "FLOOD_WAIT_30"))
        XCTAssertEqual(presenter.error, "Please wait 30s")
    }

    func testRegularApiErrorShowsMessage() {
        let presenter = ErrorPresenter()
        presenter.show(TDError.api(code: 400, message: "CHAT_NOT_FOUND"))
        XCTAssertEqual(presenter.error, "CHAT_NOT_FOUND")
    }

    func testAutoDismissAfterDelay() async {
        let presenter = ErrorPresenter()
        presenter.show("Quick error", dismissAfter: 1)
        XCTAssertNotNil(presenter.error)

        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(presenter.error, "Error should auto-dismiss after delay")
    }

    func testDismissCancelsAutoDismissTimer() async {
        let presenter = ErrorPresenter()
        presenter.show("Error", dismissAfter: 1)
        presenter.dismiss()

        // After dismiss, setting a new error should persist
        presenter.show("New error", dismissAfter: 10)
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(presenter.error, "New error", "Old dismiss timer should not clear new error")
    }
}
