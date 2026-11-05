import Security
import XCTest
@testable import OrbitextWatch

final class TDLibDatabaseKeyErrorTests: XCTestCase {
    func testKeychainStatusesSurviveLocalizedErrorBridging() {
        for status in [errSecMissingEntitlement, errSecInteractionNotAllowed, errSecNotAvailable] {
            let error = TDLibDatabaseKey.KeychainError.status(status)
            let displayed = error.localizedDescription

            XCTAssertTrue(displayed.contains("OSStatus \(status)"), displayed)
            XCTAssertFalse(displayed.contains("TDLibDatabaseKey.KeychainError"), displayed)
            if let reason = SecCopyErrorMessageString(status, nil) as String?, !reason.isEmpty {
                XCTAssertTrue(displayed.contains(reason), displayed)
            }
        }
    }

    func testUnknownKeychainStatusRemainsDiagnosable() {
        let status: OSStatus = -987_654
        let displayed = TDLibDatabaseKey.KeychainError.status(status).localizedDescription

        XCTAssertTrue(displayed.contains("OSStatus -987654"), displayed)
        XCTAssertFalse(displayed.contains("TDLibDatabaseKey.KeychainError"), displayed)
    }

    func testRandomGenerationFailurePreservesItsSecurityStatus() {
        let status = errSecNotAvailable
        let displayed = TDLibDatabaseKey.KeychainError.generationFailed(status).localizedDescription

        XCTAssertTrue(displayed.contains("OSStatus \(status)"), displayed)
        XCTAssertNotEqual(displayed, TDLibDatabaseKey.KeychainError.status(status).localizedDescription)
    }

    func testUnexpectedItemHasAnActionableDescriptionInsteadOfAnEnumName() {
        let displayed = TDLibDatabaseKey.KeychainError.unexpectedItemType.localizedDescription

        XCTAssertEqual(displayed, L10n.string("The encryption key in secure storage could not be read. Contact support before changing or reinstalling the app."))
        XCTAssertFalse(displayed.contains("TDLibDatabaseKey.KeychainError"), displayed)
    }

    func testKeychainLoadFailureDoesNotProbeLegacyDatabaseOrReplaceKey() {
        let error = TDLibDatabaseKey.KeychainError.status(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/unused-db"),
            loadKey: { throw error },
            storeKey: { _ in XCTFail("A locked key must never be replaced") },
            generateKey: {
                XCTFail("A locked key must never be replaced")
                return Data()
            },
            fileExists: { _ in
                XCTFail("A Keychain failure must not fall back to an unencrypted legacy database")
                return true
            }
        )) { thrown in
            XCTAssertEqual(thrown.localizedDescription, error.localizedDescription)
        }
    }

    func testKeychainStoreFailureDoesNotReturnAnUnprotectedKey() {
        let error = TDLibDatabaseKey.KeychainError.status(errSecMissingEntitlement)
        XCTAssertThrowsError(try TDLibDatabaseKey.resolveAtStart(
            databaseDirectory: URL(fileURLWithPath: "/unused-db"),
            loadKey: { nil },
            storeKey: { _ in throw error },
            generateKey: { Data(repeating: 7, count: 32) },
            fileExists: { _ in false }
        )) { thrown in
            XCTAssertEqual(thrown.localizedDescription, error.localizedDescription)
        }
    }
}
