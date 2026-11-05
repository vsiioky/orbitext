import Foundation
import Synchronization

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case system
    case en
    case ru
    case kk

    var id: String { rawValue }

    var locale: Locale? {
        switch self {
        case .system:
            nil
        case .en:
            Locale(identifier: "en")
        case .ru:
            Locale(identifier: "ru")
        case .kk:
            Locale(identifier: "kk")
        }
    }

    var optionLabelKey: String {
        switch self {
        case .system:
            "System"
        case .en:
            "English"
        case .ru:
            "Русский"
        case .kk:
            "Қазақша"
        }
    }

    fileprivate var localizationCode: String? {
        switch self {
        case .system:
            nil
        case .en, .ru, .kk:
            rawValue
        }
    }

    static var current: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }
}

/// Remembers the .lproj bundle resolved for the last language code, so string
/// lookups after the first skip the file system. A language without a bundle
/// is remembered too. Not thread-safe: `L10n` keeps it in its Mutex.
struct LocalizedBundleCache {
    private let loadBundle: (String) -> Bundle?
    private var cachedCode: String?
    private var cachedBundle: Bundle?

    init(loadBundle: @escaping (String) -> Bundle?) {
        self.loadBundle = loadBundle
    }

    /// A nil code follows the system language and needs no bundle.
    mutating func bundle(for code: String?) -> Bundle? {
        if cachedCode == code {
            return cachedBundle
        }
        cachedCode = code
        guard let code else {
            cachedBundle = nil
            return nil
        }
        cachedBundle = loadBundle(code)
        return cachedBundle
    }

    mutating func invalidate() {
        cachedCode = nil
        cachedBundle = nil
    }
}

enum L10n {
    /// The language picked in the app and the bundle resolved for it. Every
    /// thread that formats a string reads them.
    private struct State {
        var bundleCache = LocalizedBundleCache { code in
            Bundle.main.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
        }
        var languageOverride: AppLanguage?
    }

    private static let state = Mutex(State())

    static func useLanguage(rawValue: String) {
        state.withLock { state in
            state.languageOverride = AppLanguage(rawValue: rawValue)
            state.bundleCache.invalidate()
        }
    }

    static func string(_ key: String) -> String {
        guard let bundle = localizedBundle() else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }

        let missingValue = "__missing_localization__\(key)"
        let localized = bundle.localizedString(forKey: key, value: missingValue, table: nil)
        if localized != missingValue {
            return localized
        }

        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: currentLanguage.locale ?? .autoupdatingCurrent,
            arguments: arguments
        )
    }

    private static func localizedBundle() -> Bundle? {
        let code = currentLanguage.localizationCode
        return state.withLock { $0.bundleCache.bundle(for: code) }
    }

    private static var currentLanguage: AppLanguage {
        state.withLock { $0.languageOverride ?? AppLanguage.current }
    }
}

enum MessageNotificationPreference {
    static let storageKey = "messageNotificationsEnabled"
    static let defaultEnabled = true
}

protocol AppPreferencesStoring {
    var folderFilterEnabled: Bool { get }
    var selectedFolderId: Int64 { get }
    var messageNotificationsEnabled: Bool { get }
    var notificationsHaveLaunchedBefore: Bool { get }

    func setFolderFilterEnabled(_ enabled: Bool)
    func setSelectedFolderId(_ id: Int64)
    func setMessageNotificationsEnabled(_ enabled: Bool)
    func setNotificationsHaveLaunchedBefore(_ launched: Bool)
    func clearSessionPreferences()

    /// Set while a logout is in progress. logOut may already be in TDLib's
    /// binlog, so if the app dies first, the next launch clears app data.
    var isLogoutCleanupPending: Bool { get }
    func setLogoutCleanupPending(_ pending: Bool)
}

final class AppPreferencesStore: AppPreferencesStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var folderFilterEnabled: Bool {
        defaults.bool(forKey: "folderFilterEnabled")
    }

    var selectedFolderId: Int64 {
        Int64(defaults.string(forKey: "selectedFolderId") ?? "0") ?? 0
    }

    var messageNotificationsEnabled: Bool {
        defaults.object(forKey: MessageNotificationPreference.storageKey) as? Bool
            ?? MessageNotificationPreference.defaultEnabled
    }

    var notificationsHaveLaunchedBefore: Bool {
        defaults.bool(forKey: "notif_hasLaunchedBefore")
    }

    func setFolderFilterEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "folderFilterEnabled")
    }

    func setSelectedFolderId(_ id: Int64) {
        defaults.set(String(id), forKey: "selectedFolderId")
    }

    func setMessageNotificationsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: MessageNotificationPreference.storageKey)
    }

    func setNotificationsHaveLaunchedBefore(_ launched: Bool) {
        defaults.set(launched, forKey: "notif_hasLaunchedBefore")
    }

    func clearSessionPreferences() {
        // Message notification preference belongs to the app, not the account.
        defaults.removeObject(forKey: AppLanguage.storageKey)
        defaults.removeObject(forKey: "folderFilterEnabled")
        defaults.removeObject(forKey: "selectedFolderId")
        defaults.removeObject(forKey: QuickReactionPreference.storageKey)
        defaults.removeObject(forKey: "notif_hasLaunchedBefore")
    }

    var isLogoutCleanupPending: Bool {
        defaults.bool(forKey: "logoutCleanupPending")
    }

    func setLogoutCleanupPending(_ pending: Bool) {
        if pending {
            defaults.set(true, forKey: "logoutCleanupPending")
        } else {
            defaults.removeObject(forKey: "logoutCleanupPending")
        }
    }
}
