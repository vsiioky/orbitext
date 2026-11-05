import XCTest

/// App Store declarations the built watch app and widget must carry. They are
/// read from the packaged bundles, so a stale generated plist or a manifest
/// missing from the build fails here.
final class ReleaseComplianceTests: XCTestCase {
    /// The app ships OpenSSL, MTProto and SQLCipher; see
    /// docs/release/export-compliance.md for the exemption claimed.
    func testAppDeclaresNonExemptEncryption() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, true)
    }

    func testAppPrivacyManifestDeclaresRequiredReasonAPIs() throws {
        let reasons = try declaredReasons(in: Bundle.main)

        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1", "1C8F.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }

    func testWidgetPrivacyManifestDeclaresUserDefaults() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("OrbitextWidget.appex")))
        let reasons = try declaredReasons(in: widget)

        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1", "1C8F.1"])
    }

    private func declaredReasons(in bundle: Bundle) throws -> [String: [String]] {
        let url = try XCTUnwrap(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "no PrivacyInfo.xcprivacy in \(bundle.bundleURL.lastPathComponent)"
        )
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in entries {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        return reasons
    }
}
