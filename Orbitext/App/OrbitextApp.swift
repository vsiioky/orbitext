import Foundation
import os
import SwiftUI
import WatchKit

@main
struct OrbitextApp: App {
    /// Nil only in the unit-test host. Each test builds its own AppState over
    /// a mock transport that lives in the test bundle, so the host app starts
    /// no transport and shows nothing.
    @State private var appState: AppState?
    @WKApplicationDelegateAdaptor private var appDelegate: OrbitextAppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    init() {
        L10n.useLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? AppLanguage.system.rawValue)
        guard !AppRuntime.isRunningTests else { return }
        let appState = Self.makeAppState()
        appState.imageCache.removePlaybackCopiesOfEarlierRuns()
        Task.detached(priority: .background) {
            VoiceManager.removePlaybackCopiesOfEarlierRuns()
        }
        RemotePushCoordinator.shared.attach(appState)
        _appState = State(initialValue: appState)
    }

    var body: some Scene {
        WindowGroup {
            if let appState {
                RootView()
                    .injectingAppState(appState)
                    .environment(\.locale, effectiveLocale)
                    .id(appLanguage)
                    .onChange(of: appLanguage) { _, newValue in
                        L10n.useLanguage(rawValue: newValue)
                    }
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        switch phase {
                        case .active:
                            appState.handleBecameActive()
                        case .background:
                            appState.handleEnteredBackground()
                        default:
                            break
                        }
                    }
                    .onOpenURL { url in
                        handleDeepLink(url, appState: appState)
                    }
            } else {
                Color.clear
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.taskIdentifier)) {
            guard let state = await appState else { return }
            await state.performBackgroundRefresh()
        }
    }

    /// The app over TDLib; in a Debug build asked for demo mode, over invented data.
    private static func makeAppState() -> AppState {
        #if DEBUG
        if let demo = DemoLaunch.current { return demo.makeAppState() }
        #endif
        return AppState(service: TelegramServiceFactory.live())
    }

    private var effectiveLocale: Locale {
        let selectedLanguage = AppLanguage(rawValue: appLanguage) ?? .system
        return selectedLanguage.locale ?? .autoupdatingCurrent
    }

    @MainActor
    private func handleDeepLink(_ url: URL, appState: AppState) {
        // orbitext://chat/<id> - shared with widget (OrbitextWidget.swift)
        // and any future URL-driven entry point. Parsing logic lives on
        // AppRouter so AppRouterTests can cover the URL grammar.
        guard let chatId = AppRouter.chatId(fromDeepLink: url) else { return }
        appState.router.openChat(chatId)
    }
}

@MainActor
protocol RemotePushHandling: AnyObject {
    func registerPushDeviceToken(_ token: Data) async
    func handleRemotePush(userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult
}

@MainActor
final class RemotePushCoordinator {
    static let shared = RemotePushCoordinator()

    private weak var handler: (any RemotePushHandling)?
    private var pendingDeviceToken: Data?
    private var didRequestRegistration = false

    private init() {}

    func attach(_ handler: any RemotePushHandling) {
        self.handler = handler

        if let pendingDeviceToken {
            self.pendingDeviceToken = nil
            Task { await handler.registerPushDeviceToken(pendingDeviceToken) }
        }
    }

    func registerForRemoteNotifications() {
        guard !didRequestRegistration,
              !AppRuntime.isRunningTests else { return }
        didRequestRegistration = true
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        guard let handler else {
            pendingDeviceToken = deviceToken
            return
        }

        Task {
            await handler.registerPushDeviceToken(deviceToken)
        }
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard let handler else { return .noData }
        return await handler.handleRemotePush(userInfo: userInfo)
    }
}

final class OrbitextAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        RemotePushCoordinator.shared.registerForRemoteNotifications()
    }

    func applicationDidBecomeActive() {
        RemotePushCoordinator.shared.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Logger.app.info("APNs token received (\(deviceToken.count) bytes)")
        Task { @MainActor in
            RemotePushCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Logger.app.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let result = await RemotePushCoordinator.shared.handleRemoteNotification(userInfo)
            completionHandler(result)
        }
    }
}

private enum AppRuntime {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        return NSClassFromString("XCTestCase") != nil
    }
}

extension View {
    /// Injects everything the views read with `@Environment`. The app and the
    /// render tests share this one list, so a view that reads an object nobody
    /// injected fails a test instead of trapping on the watch.
    func injectingAppState(_ appState: AppState) -> some View {
        environment(appState)
            .environment(appState.authManager)
            .environment(appState.chatRepository)
            .environment(appState.messageManager)
            .environment(appState.chatMessageStore)
            .environment(appState.botKeyboardStore)
            .environment(appState.sponsoredMessageStore)
            .environment(appState.networkMonitor)
            .environment(appState.voiceManager)
            .environment(appState.errorPresenter)
            .environment(appState.imageCache)
            .environment(appState.router)
    }
}

struct RootView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(ErrorPresenter.self) private var errorPresenter

    @Environment(NetworkMonitor.self) private var networkMonitor
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        Group {
            switch authManager.authState {
            case .idle:
                // The first active scene starts the client
                // (AppState.handleBecameActive). A background launch starts
                // nothing; see LeasePolicy.remotePush.
                ProgressView("Loading...")
            case .ready:
                ChatListView()
            default:
                AuthFlowView()
            }
        }
        .id(appLanguage)
        .onAppear {
            L10n.useLanguage(rawValue: appLanguage)
        }
        .onChange(of: appLanguage) { _, newValue in
            L10n.useLanguage(rawValue: newValue)
        }
        .overlay {
            ConnectionRingView(networkMonitor: networkMonitor)
        }
        .overlay(alignment: .bottom) {
            if let error = errorPresenter.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: networkMonitor.connectionStatus)
        .animation(.easeInOut(duration: 0.25), value: errorPresenter.error)
    }
}
