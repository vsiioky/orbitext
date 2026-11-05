import XCTest

/// Settings the built watch app must carry in its own Info.plist. They are
/// read from the packaged bundle, so a stale generated plist fails here too.
final class PackagedConfigurationTests: XCTestCase {
    /// TDLib falls back to plain HTTP against Telegram's IP addresses when its
    /// QUIC and WebSocket transports are blocked, and ATS rejects that unless
    /// the app opts out.
    func testPackagedAppAllowsTDLibsHTTPFallbackToTelegramIPs() throws {
        let transportSecurity = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )

        XCTAssertEqual(transportSecurity["NSAllowsArbitraryLoads"] as? Bool, true)
    }
}
