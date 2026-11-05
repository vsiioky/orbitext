import SwiftUI
import XCTest
@testable import OrbitextWatch

/// The unit-test host builds no AppState, so nothing else puts the app's
/// composition in front of a view: the environment list in `OrbitextApp`
/// and the factory that picks the transport. These tests do.
@MainActor
final class AppEnvironmentTests: XCTestCase {
    private var apps: [AppState] = []

    override func tearDown() async throws {
        for app in apps {
            app.eventTask?.cancel()
            app.networkMonitor.pause()
            app.resetSyncPipeline()
        }
        apps = []
        try await super.tearDown()
    }

    func testInjectionProvidesEveryObjectTheViewsRead() {
        let app = makeApp()
        let report = EnvironmentReport()

        render(EnvironmentProbe(report: report).injectingAppState(app))

        XCTAssertTrue(report.didRender, "The probe never rendered")
        XCTAssertEqual(report.missing, [], "A view reading these would trap on the watch")
    }

    func testRootViewRendersWhileTheSessionIsStarting() {
        let app = makeApp()
        app.authManager.authState = .idle

        let image = render(RootView().injectingAppState(app))

        XCTAssertNotNil(image)
    }

    func testAuthMethodPickerRenders() {
        let app = makeApp()
        app.authManager.authState = .waitPhoneNumber

        let image = render(AuthMethodView(method: .constant(.none)).injectingAppState(app))

        XCTAssertNotNil(image)
    }

    func testLiveFactoryBuildsTheNativeTransport() {
        let service = TelegramServiceFactory.live()

        XCTAssertTrue(service is TDLibService, "The app would run on \(type(of: service))")
    }

    // MARK: - Helpers

    @discardableResult
    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 184, height: 224))
        renderer.scale = 1
        return renderer.cgImage
    }

    private func makeApp() -> AppState {
        let app = AppState(
            service: MockTelegramService(),
            notificationManager: MockNotificationManager(),
            widgetSync: MockWidgetSync(),
            preferences: AppPreferencesStore(defaults: makeTestDefaults())
        )
        app.networkMonitor.pause()
        apps.append(app)
        return app
    }
}

@MainActor
private final class EnvironmentReport {
    var didRender = false
    var missing: [String] = []
}

/// Reads every type the app's views take from the environment, as optionals:
/// a plain read of an object nobody injected traps instead of reporting.
private struct EnvironmentProbe: View {
    let report: EnvironmentReport
    @Environment(AppState.self) private var appState: AppState?
    @Environment(AuthManager.self) private var authManager: AuthManager?
    @Environment(ChatRepository.self) private var chatRepository: ChatRepository?
    @Environment(MessageManager.self) private var messageManager: MessageManager?
    @Environment(ChatMessageStore.self) private var chatMessageStore: ChatMessageStore?
    @Environment(BotKeyboardStore.self) private var botKeyboardStore: BotKeyboardStore?
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    @Environment(VoiceManager.self) private var voiceManager: VoiceManager?
    @Environment(ErrorPresenter.self) private var errorPresenter: ErrorPresenter?
    @Environment(ImageCache.self) private var imageCache: ImageCache?
    @Environment(AppRouter.self) private var router: AppRouter?

    var body: some View {
        let present: [(name: String, isInjected: Bool)] = [
            ("AppState", appState != nil),
            ("AuthManager", authManager != nil),
            ("ChatRepository", chatRepository != nil),
            ("MessageManager", messageManager != nil),
            ("ChatMessageStore", chatMessageStore != nil),
            ("BotKeyboardStore", botKeyboardStore != nil),
            ("NetworkMonitor", networkMonitor != nil),
            ("VoiceManager", voiceManager != nil),
            ("ErrorPresenter", errorPresenter != nil),
            ("ImageCache", imageCache != nil),
            ("AppRouter", router != nil)
        ]
        report.didRender = true
        report.missing = present.filter { !$0.isInjected }.map(\.name)
        return Color.clear
    }
}
