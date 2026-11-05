import XCTest
@testable import OrbitextWatch

@MainActor
final class AuthManagerTests: XCTestCase {
    func testInitialStateIsIdle() {
        let service = MockTelegramService()
        let errorPresenter = ErrorPresenter()
        let authManager = AuthManager(service: service, errorPresenter: errorPresenter)

        XCTAssertEqual(authManager.authState, .idle)
    }

    func testSendPhoneCallsServiceAndResetsLoading() async {
        let service = MockTelegramService()
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())
        authManager.authState = .waitPhoneNumber

        await authManager.sendPhone("+15550100123")

        XCTAssertEqual(service.sentPhoneNumbers, ["+15550100123"])
        XCTAssertFalse(authManager.isLoading)
        XCTAssertNil(authManager.errorPresenter?.error)
    }

    func testSendCodeShowsErrorOnFailure() async {
        let service = MockTelegramService()
        service.codeError = TestError.failed("Invalid code")
        let errorPresenter = ErrorPresenter()
        let authManager = AuthManager(service: service, errorPresenter: errorPresenter)

        await authManager.sendCode("12345")

        XCTAssertEqual(service.sentCodes.count, 0)
        XCTAssertEqual(errorPresenter.error, "Invalid code")
        XCTAssertFalse(authManager.isLoading)
    }

    func testRequestQRCodeAuthIsThrottledWithoutForceRefresh() async {
        let service = MockTelegramService()
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())

        await authManager.requestQRCodeAuth()
        await authManager.requestQRCodeAuth()

        XCTAssertEqual(service.qrRequestCount, 1)
    }

    /// Back out of the QR screen and come back: the link is gone, so the
    /// anti-spam window no longer has anything to protect.
    func testLeavingTheQRFlowLetsTheNextRequestThrough() async {
        let service = MockTelegramService()
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())
        await authManager.requestQRCodeAuth()
        authManager.setQRCodeLink("tg://login?token=one")

        authManager.clearQRCodeLinkAndThrottle()
        await authManager.requestQRCodeAuth()

        XCTAssertEqual(service.qrRequestCount, 2)
    }

    /// Every auth update that is not the QR wait clears the link. That is
    /// not the user leaving the flow, so it may not reopen the window.
    func testAnAuthUpdateDroppingTheLinkKeepsTheAntiSpamWindow() async {
        let service = MockTelegramService()
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())
        await authManager.requestQRCodeAuth()
        authManager.setQRCodeLink("tg://login?token=one")

        authManager.setQRCodeLink(nil)
        await authManager.requestQRCodeAuth()

        XCTAssertEqual(service.qrRequestCount, 1)
    }

    func testQRFlowIsTrueForOtherDeviceConfirmationState() {
        let service = MockTelegramService()
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())

        authManager.authState = .waitOtherDeviceConfirmation

        XCTAssertTrue(authManager.isInQRFlow)
    }

    func testAuthEventDeduperSuppressesRepeatedQRCodeState() {
        var deduper = AuthEventDeduper()

        XCTAssertTrue(deduper.shouldEmitAuthState(.waitPhoneNumber))
        XCTAssertTrue(deduper.shouldEmitQRCodeLink("tg://login?token=one"))
        XCTAssertTrue(deduper.shouldEmitAuthState(.waitOtherDeviceConfirmation))

        XCTAssertFalse(deduper.shouldEmitQRCodeLink("tg://login?token=one"))
        XCTAssertFalse(deduper.shouldEmitAuthState(.waitOtherDeviceConfirmation))
    }

    func testAuthEventDeduperAllowsNewQRCodeLinkAndClearsWhenLeavingQRFlow() {
        var deduper = AuthEventDeduper()

        XCTAssertTrue(deduper.shouldEmitQRCodeLink("tg://login?token=one"))
        XCTAssertFalse(deduper.shouldEmitQRCodeLink("tg://login?token=one"))

        XCTAssertTrue(deduper.shouldEmitQRCodeLink("tg://login?token=two"))
        XCTAssertTrue(deduper.shouldEmitAuthState(.waitPhoneNumber))
        XCTAssertTrue(deduper.shouldEmitQRCodeLink("tg://login?token=two"))
    }

    func testAppStateClearsQRCodeLinkWhenAuthLeavesQRFlow() {
        let service = MockTelegramService()
        let appState = AppState(
            service: service,
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )

        appState.handleEvent(.authStateChanged(.waitOtherDeviceConfirmation))
        appState.handleEvent(.qrCodeLink("tg://login?token=current"))
        XCTAssertEqual(appState.authManager.qrCodeLink, "tg://login?token=current")

        appState.handleEvent(.authStateChanged(.waitPhoneNumber))

        XCTAssertNil(appState.authManager.qrCodeLink)
        XCTAssertEqual(appState.authManager.authState, .waitPhoneNumber)

        appState.handleEvent(.qrCodeLink("tg://login?token=late"))
        XCTAssertNil(appState.authManager.qrCodeLink)
    }

    /// A cancelled auth task must NOT bubble up to the
    /// errorPresenter as a user-visible error. Cancellation is the user's
    /// intent (navigated away / scenePhase change) - not a failure to
    /// surface a toast and failure haptic for.
    func testCancelledAuthDoesNotShowUserError() async {
        let service = MockTelegramService()
        service.phoneError = CancellationError()
        let errorPresenter = ErrorPresenter()
        let authManager = AuthManager(service: service, errorPresenter: errorPresenter)
        authManager.authState = .waitPhoneNumber

        await authManager.sendPhone("+15550100123")

        XCTAssertNil(errorPresenter.error, "cancelled auth must not surface a user-visible error")
        XCTAssertFalse(authManager.isLoading)
    }

    func testConcurrentPasswordSubmitsAreIgnored() async {
        let service = MockTelegramService()
        service.authActionDelay = .milliseconds(100)
        let authManager = AuthManager(service: service, errorPresenter: ErrorPresenter())

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await authManager.sendPassword("secret") }
            group.addTask { await authManager.sendPassword("secret") }
            await group.waitForAll()
        }

        XCTAssertEqual(service.sentPasswords.count, 1)
    }
}
