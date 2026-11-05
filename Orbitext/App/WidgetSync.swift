import Foundation
import os
import WidgetKit

protocol WidgetSyncing {
    func update(chats: [ChatInfo], isInBackground: Bool)
}

struct WidgetSyncService: WidgetSyncing {
    private let defaults: UserDefaults?
    private let reloadTimelines: () -> Void

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.App.widgetSuite),
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.defaults = defaults
        self.reloadTimelines = reloadTimelines
    }

    func update(chats: [ChatInfo], isInBackground: Bool) {
        guard let defaults else {
            Logger.app.warning("WidgetSync: app group defaults unavailable for suite '\(AppConstants.App.widgetSuite, privacy: .public)'")
            return
        }
        let totalUnread = chats.reduce(0) { $0 + $1.unreadCount }
        let topChat = chats.first(where: { $0.unreadCount > 0 })
        // The widget has no access to the app's VoiceOver helpers; store the
        // spoken form so neither its text nor VoiceOver shows mask glyphs.
        let preview = topChat?.lastMessage?.content.textPreview.speakingSpoilerMasks
        // Most initial-sync/status updates do not change widget content.
        // Compare the persisted fields so relaunches and foreground changes
        // also avoid redundant defaults writes and WidgetKit reload requests.
        guard defaults.object(forKey: "totalUnread") as? Int != totalUnread
            || defaults.string(forKey: "lastChatName") != topChat?.title
            || defaults.string(forKey: "lastMessagePreview") != preview
            || defaults.object(forKey: "lastChatId") as? Int64 != topChat?.id else { return }

        defaults.set(totalUnread, forKey: "totalUnread")
        if let topChat {
            defaults.set(topChat.title, forKey: "lastChatName")
            defaults.set(preview, forKey: "lastMessagePreview")
            defaults.set(topChat.id, forKey: "lastChatId")
        } else {
            defaults.removeObject(forKey: "lastChatName")
            defaults.removeObject(forKey: "lastMessagePreview")
            defaults.removeObject(forKey: "lastChatId")
        }
        reloadTimelines()
    }
}
