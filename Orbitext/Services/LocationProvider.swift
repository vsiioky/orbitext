import CoreLocation
import Observation

enum LocationRequestFailure: Equatable {
    case denied
    case restricted
    case unavailable
    case timedOut

    var messageKey: String {
        switch self {
        case .denied: "Allow location access for Orbitext in Settings, then retry."
        case .restricted: "Location access is restricted on this device."
        case .unavailable: "Could not determine your location. Try again."
        case .timedOut: "Location request timed out. Try again."
        }
    }
}

enum LocationRequestState: Equatable {
    case idle
    case requestingPermission
    case locating
    case ready(SharedLocation)
    case failed(LocationRequestFailure)

    var isBusy: Bool {
        switch self {
        case .requestingPermission, .locating: true
        default: false
        }
    }
}

/// A driver is created for each request. Old delegate callbacks therefore
/// cannot satisfy a new request after cancellation or retry.
@MainActor
protocol LocationRequesting: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onFailure: ((LocationRequestFailure) -> Void)? { get set }
    func requestAuthorization()
    func requestLocation()
    func stop()
}

@MainActor
@Observable
final class LocationProvider {
    private(set) var state: LocationRequestState = .idle

    @ObservationIgnored private let makeDriver: @MainActor () -> any LocationRequesting
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var driver: (any LocationRequesting)?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var didRequestLocation = false

    init(
        timeout: Duration = .seconds(30),
        now: @escaping () -> Date = Date.init,
        makeDriver: @escaping @MainActor () -> any LocationRequesting = { CoreLocationRequestDriver() }
    ) {
        self.timeout = timeout
        self.now = now
        self.makeDriver = makeDriver
    }

    func request() {
        guard !state.isBusy else { return }
        stopRequest()
        let id = UUID()
        requestID = id
        state = .locating
        let driver = makeDriver()
        self.driver = driver
        driver.onAuthorizationChange = { [weak self] status in
            guard let self, self.requestID == id else { return }
            self.handleAuthorization(status)
        }
        driver.onLocations = { [weak self] locations in
            guard let self, self.requestID == id else { return }
            self.handleLocations(locations)
        }
        driver.onFailure = { [weak self] failure in
            guard let self, self.requestID == id else { return }
            self.finish(.failed(failure))
        }
        timeoutTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.requestID == id else { return }
            self.finish(.failed(.timedOut))
        }
        handleAuthorization(driver.authorizationStatus)
    }

    func cancel() {
        stopRequest()
        state = .idle
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            guard state != .requestingPermission else { return }
            state = .requestingPermission
            driver?.requestAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !didRequestLocation else { return }
            didRequestLocation = true
            state = .locating
            driver?.requestLocation()
        case .denied:
            finish(.failed(.denied))
        case .restricted:
            finish(.failed(.restricted))
        @unknown default:
            finish(.failed(.unavailable))
        }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard didRequestLocation else { return }
        // requestLocation can provide a cached sample. Accept a recent valid
        // fix only; the timeout remains active if all samples are stale.
        let currentTime = now()
        let sample = locations.filter {
            let age = currentTime.timeIntervalSince($0.timestamp)
            return age >= -5 && age <= 60 && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy.isFinite
                && CLLocationCoordinate2DIsValid($0.coordinate)
        }.max { $0.timestamp < $1.timestamp }
        guard let sample else { return }
        let location = SharedLocation(
            latitude: sample.coordinate.latitude,
            longitude: sample.coordinate.longitude,
            horizontalAccuracy: sample.horizontalAccuracy
        )
        guard location.isValid else { return }
        finish(.ready(location))
    }

    private func finish(_ newState: LocationRequestState) {
        stopRequest()
        state = newState
    }

    private func stopRequest() {
        requestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        driver?.onAuthorizationChange = nil
        driver?.onLocations = nil
        driver?.onFailure = nil
        driver?.stop()
        driver = nil
        didRequestLocation = false
    }
}

@MainActor
private final class CoreLocationRequestDriver: NSObject, LocationRequesting, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((LocationRequestFailure) -> Void)?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChange?(self.manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.onLocations?(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure: LocationRequestFailure = (error as? CLError)?.code == .denied ? .denied : .unavailable
        Task { @MainActor [weak self] in self?.onFailure?(failure) }
    }
}
