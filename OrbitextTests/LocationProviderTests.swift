import CoreLocation
import XCTest
@testable import OrbitextWatch

@MainActor
final class LocationProviderTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testPermissionIsRequestedOnceAndCoordinatesWaitForAuthorization() {
        let driver = MockLocationRequestDriver(status: .notDetermined)
        let provider = LocationProvider(makeDriver: { driver })

        provider.request()
        provider.request()
        driver.onAuthorizationChange?(.notDetermined)

        XCTAssertEqual(provider.state, .requestingPermission)
        XCTAssertEqual(driver.authorizationRequests, 1)
        XCTAssertEqual(driver.locationRequests, 0)

        driver.onAuthorizationChange?(.authorizedWhenInUse)
        driver.onAuthorizationChange?(.authorizedWhenInUse)
        XCTAssertEqual(provider.state, .locating)
        XCTAssertEqual(driver.locationRequests, 1)
        provider.cancel()
    }

    func testDeniedPermissionNeverRequestsCoordinates() {
        let driver = MockLocationRequestDriver(status: .denied)
        let provider = LocationProvider(makeDriver: { driver })

        provider.request()

        XCTAssertEqual(provider.state, .failed(.denied))
        XCTAssertEqual(driver.locationRequests, 0)
        XCTAssertEqual(driver.stopCalls, 1)
    }

    func testRestrictedPermissionHasDistinctState() {
        let driver = MockLocationRequestDriver(status: .restricted)
        let provider = LocationProvider(makeDriver: { driver })

        provider.request()

        XCTAssertEqual(provider.state, .failed(.restricted))
        XCTAssertEqual(driver.authorizationRequests, 0)
        XCTAssertEqual(driver.locationRequests, 0)
    }

    func testRecentValidFixStopsLocationUpdates() {
        let driver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        let provider = LocationProvider(now: { self.timestamp }, makeDriver: { driver })
        provider.request()

        driver.onLocations?([sample(latitude: 0.25, longitude: 0.5, accuracy: 24)])

        XCTAssertEqual(provider.state, .ready(SharedLocation(latitude: 0.25, longitude: 0.5, horizontalAccuracy: 24)))
        XCTAssertEqual(driver.stopCalls, 1)
        XCTAssertNil(driver.onLocations)
        XCTAssertNil(driver.onAuthorizationChange)
    }

    func testStaleFutureAndInvalidFixesCannotBecomeShareable() {
        let driver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        let provider = LocationProvider(now: { self.timestamp }, makeDriver: { driver })
        provider.request()

        driver.onLocations?([
            sample(age: 61),
            sample(age: -10),
            sample(accuracy: -1),
            sample(latitude: 91),
            sample(accuracy: .infinity)
        ])

        XCTAssertEqual(provider.state, .locating)
        provider.cancel()
    }

    func testCancelRejectsLateFixAndPermissionCallbackDuringNewRequest() {
        let firstDriver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        let secondDriver = MockLocationRequestDriver(status: .notDetermined)
        var drivers = [firstDriver, secondDriver]
        let provider = LocationProvider(now: { self.timestamp }, makeDriver: { drivers.removeFirst() })
        provider.request()
        let oldLocations = firstDriver.onLocations
        let oldAuthorization = firstDriver.onAuthorizationChange

        provider.cancel()
        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(firstDriver.stopCalls, 1)
        provider.request()
        oldLocations?([sample()])
        oldAuthorization?(.authorizedWhenInUse)

        XCTAssertEqual(provider.state, .requestingPermission)
        XCTAssertEqual(secondDriver.locationRequests, 0)
        provider.cancel()
    }

    func testDriverFailureClearsRequestAndAllowsRetry() {
        let firstDriver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        let secondDriver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        var drivers = [firstDriver, secondDriver]
        let provider = LocationProvider(makeDriver: { drivers.removeFirst() })
        provider.request()
        firstDriver.onFailure?(.unavailable)

        XCTAssertEqual(provider.state, .failed(.unavailable))
        XCTAssertEqual(firstDriver.stopCalls, 1)
        provider.request()
        XCTAssertEqual(provider.state, .locating)
        XCTAssertEqual(secondDriver.locationRequests, 1)
        provider.cancel()
    }

    func testTimeoutStopsDriverAndRejectsLateLocation() async throws {
        let driver = MockLocationRequestDriver(status: .authorizedWhenInUse)
        let provider = LocationProvider(timeout: .milliseconds(5), now: { self.timestamp }, makeDriver: { driver })
        provider.request()
        let lateLocations = driver.onLocations
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(provider.state, .failed(.timedOut))
        XCTAssertEqual(driver.stopCalls, 1)
        lateLocations?([sample()])
        XCTAssertEqual(provider.state, .failed(.timedOut))
    }

    private func sample(
        latitude: Double = 0,
        longitude: Double = 0,
        accuracy: Double = 10,
        age: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: timestamp.addingTimeInterval(-age)
        )
    }
}

@MainActor
private final class MockLocationRequestDriver: LocationRequesting {
    let authorizationStatus: CLAuthorizationStatus
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((LocationRequestFailure) -> Void)?
    var authorizationRequests = 0
    var locationRequests = 0
    var stopCalls = 0

    init(status: CLAuthorizationStatus) { authorizationStatus = status }
    func requestAuthorization() { authorizationRequests += 1 }
    func requestLocation() { locationRequests += 1 }
    func stop() { stopCalls += 1 }
}
