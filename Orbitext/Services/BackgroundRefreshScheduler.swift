import os
import WatchKit

@MainActor
enum BackgroundRefreshScheduler {
    static let taskIdentifier = "com.orbitext.refresh"
    private static let refreshInterval: TimeInterval = AppConstants.App.backgroundRefreshInterval

    static func scheduleNext() {
        let interval = refreshInterval
        let preferredDate = Date(timeIntervalSinceNow: interval)
        // WatchKit does not document the queue of this completion (the
        // simulator uses the main thread). Written here, the closure would be
        // main actor-isolated, and the Swift 6 mode checks that isolation when
        // it runs: on another queue the app would stop. It only logs, so it is
        // @Sendable and needs no actor.
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: taskIdentifier as NSSecureCoding & NSObjectProtocol
        ) { @Sendable error in
            if let error {
                Logger.app.error("Failed to schedule background refresh: \(error.localizedDescription)")
            } else {
                Logger.app.debug("Background refresh scheduled in \(Int(interval))s")
            }
        }
    }
}
