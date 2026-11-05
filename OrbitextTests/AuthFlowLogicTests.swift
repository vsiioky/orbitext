import XCTest
@testable import OrbitextWatch

final class AuthFlowLogicTests: XCTestCase {
    // MARK: - effectiveMethod

    func testExplicitPhoneMethodWinsEvenWithQRLink() {
        let result = AuthFlowLogic.effectiveMethod(method: .phone, hasQRCodeLink: true)

        XCTAssertEqual(result, .phone, "An explicit phone pick must not be overridden by a stale QR link")
    }

    func testExplicitQRMethodStaysQR() {
        XCTAssertEqual(AuthFlowLogic.effectiveMethod(method: .qr, hasQRCodeLink: false), .qr)
    }

    /// The service can ask for a QR link before the user picks anything: the
    /// code they already see has to be actionable.
    func testNoMethodWithQRLinkFallsThroughToQR() {
        XCTAssertEqual(AuthFlowLogic.effectiveMethod(method: .none, hasQRCodeLink: true), .qr)
    }

    func testNoMethodAndNoQRLinkShowsThePicker() {
        XCTAssertEqual(AuthFlowLogic.effectiveMethod(method: .none, hasQRCodeLink: false), .none)
    }

    // MARK: - shouldShowBackButton

    func testBackButtonHiddenOnTheMethodPicker() {
        XCTAssertFalse(back(.waitPhoneNumber, method: .none, qrLink: false))
    }

    func testBackButtonShownOnPhoneInput() {
        XCTAssertTrue(back(.waitPhoneNumber, method: .phone, qrLink: false))
    }

    func testBackButtonShownOnQRScreen() {
        XCTAssertTrue(back(.waitPhoneNumber, method: .qr, qrLink: true))
    }

    func testBackButtonShownOnQRScreenReachedByFallthrough() {
        XCTAssertTrue(back(.waitPhoneNumber, method: .none, qrLink: true))
    }

    func testBackButtonShownWhileWaitingForTheOtherDevice() {
        XCTAssertTrue(back(.waitOtherDeviceConfirmation, method: .qr, qrLink: true))
        XCTAssertTrue(back(.waitOtherDeviceConfirmation, method: .none, qrLink: false))
    }

    func testBackButtonShownOnCodeInput() {
        XCTAssertTrue(back(.waitCode, method: .phone, qrLink: false))
    }

    func testBackButtonShownOnTwoFactorPassword() {
        XCTAssertTrue(back(.waitPassword(hint: "hint"), method: .phone, qrLink: false))
    }

    func testBackButtonHiddenWhereTheScreenHasItsOwnWayOut() {
        XCTAssertFalse(back(.idle, method: .none, qrLink: false))
        XCTAssertFalse(back(.ready, method: .phone, qrLink: false))
        XCTAssertFalse(back(.closing, method: .phone, qrLink: false))
        XCTAssertFalse(back(.error("boom"), method: .phone, qrLink: false), "The error screen has Retry")
    }

    private func back(_ state: AuthState, method: AuthMethod, qrLink: Bool) -> Bool {
        AuthFlowLogic.shouldShowBackButton(authState: state, method: method, hasQRCodeLink: qrLink)
    }
}
