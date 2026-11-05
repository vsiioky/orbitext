import XCTest
@testable import OrbitextWatch

final class LocalizedBundleCacheTests: XCTestCase {
    func testBundleIsLoadedOncePerLanguageUntilTheLanguageChanges() {
        let loads = LoadLog()
        var cache = LocalizedBundleCache { code in
            loads.record(code)
            return Bundle.main
        }

        for _ in 0..<3 { XCTAssertNotNil(cache.bundle(for: "ru")) }
        XCTAssertEqual(loads.codes, ["ru"], "Every string lookup walked the file system again")

        XCTAssertNotNil(cache.bundle(for: "kk"))
        XCTAssertEqual(loads.codes, ["ru", "kk"])
    }

    func testInvalidatingForcesTheNextLookupToLoadAgain() {
        let loads = LoadLog()
        var cache = LocalizedBundleCache { code in
            loads.record(code)
            return Bundle.main
        }
        _ = cache.bundle(for: "ru")

        cache.invalidate()
        _ = cache.bundle(for: "ru")

        XCTAssertEqual(loads.codes, ["ru", "ru"], "A language change must pick up the bundle again")
    }

    func testSystemLanguageNeedsNoBundle() {
        let loads = LoadLog()
        var cache = LocalizedBundleCache { code in
            loads.record(code)
            return Bundle.main
        }

        XCTAssertNil(cache.bundle(for: nil))
        XCTAssertTrue(loads.codes.isEmpty)
    }

    func testMissingLanguageBundleIsRememberedInsteadOfSearchedForAgain() {
        let loads = LoadLog()
        var cache = LocalizedBundleCache { code in
            loads.record(code)
            return nil
        }

        XCTAssertNil(cache.bundle(for: "xx"))
        XCTAssertNil(cache.bundle(for: "xx"))

        XCTAssertEqual(loads.codes, ["xx"])
    }

    func testStringsFollowTheSelectedLanguage() {
        // Restore what the host app selected from its settings, not .system.
        let selected = UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? AppLanguage.system.rawValue
        addTeardownBlock { L10n.useLanguage(rawValue: selected) }

        L10n.useLanguage(rawValue: AppLanguage.ru.rawValue)
        XCTAssertEqual(L10n.string("Retry"), "Повторить")
        XCTAssertEqual(L10n.string("Retry"), "Повторить", "The cached bundle must keep answering in Russian")

        L10n.useLanguage(rawValue: AppLanguage.kk.rawValue)
        XCTAssertEqual(L10n.string("Retry"), "Қайталау", "A stale cached bundle answered in the previous language")

        L10n.useLanguage(rawValue: AppLanguage.en.rawValue)
        XCTAssertEqual(L10n.string("Retry"), "Retry")
    }
}

private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var codes: [String] { lock.withLock { stored } }
    func record(_ code: String) { lock.withLock { stored.append(code) } }
}
