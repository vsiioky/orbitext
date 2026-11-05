import Network
import Observation
import SwiftUI

enum TDLibConnectionPhase: String, Sendable {
    case waitingForNetwork = "connectionStateWaitingForNetwork"
    case connecting = "connectionStateConnecting"
    case updating = "connectionStateUpdating"
    case ready = "connectionStateReady"
    case unknown

    init(rawTDLibState: String) {
        self = TDLibConnectionPhase(rawValue: rawTDLibState) ?? .unknown
    }

    var isReady: Bool {
        self == .ready
    }

    /// TDLib is connected and can serve cached data from the local database.
    /// True for both `updating` (downloading diffs) and `ready` (fully synced).
    var canServeRequests: Bool {
        self == .updating || self == .ready
    }
}

enum ConnectionStatus: Equatable {
    case connected
    case connecting
    case offline

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .orange
        case .offline: .red
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        }
    }
}

@MainActor
@Observable
final class NetworkMonitor {
    var connectionStatus: ConnectionStatus {
        // TDLib connected - always trust this
        if tdlibState.canServeRequests {
            return .connected
        }
        // Only show offline when BOTH NWPath and TDLib agree there's no network
        if hasObservedPath && !nwPathConnected && tdlibState == .waitingForNetwork {
            return .offline
        }
        // Everything else is transient - show connecting
        return .connecting
    }

    var isConnected: Bool {
        nwPathConnected && tdlibState.isReady
    }

    var tdlibState: TDLibConnectionPhase = .unknown

    var connectionType: ConnectionType = .unknown
    var onReconnected: (() -> Void)?
    private var wasConnected = true
    private var hasObservedPath = false

    enum ConnectionType: String {
        case wifi = "Wi-Fi"
        case cellular = "LTE"
        case bluetooth = "BT"
        case unknown = "-"

        var iconName: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .bluetooth: return "link"
            case .unknown: return "network"
            }
        }
    }

    private var nwPathConnected = false
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.orbitext.network")

    init(startMonitoring: Bool = true) {
        if startMonitoring {
            setupMonitor()
        }
    }

    nonisolated deinit {
        // Monitor cleanup happens in pause()
    }

    // MARK: - Pause/Resume

    /// Whether the path monitor runs: `pause()` stops it, `resume()` starts it.
    var isMonitoring: Bool {
        monitor != nil
    }

    func pause() {
        monitor?.cancel()
        monitor = nil
    }

    func resume() {
        guard monitor == nil else { return }
        setupMonitor()
    }

    // MARK: - Private

    private func setupMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let status = path.status
            let activeType = Self.connectionType(
                isSatisfied: status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesCellular: path.usesInterfaceType(.cellular),
                usesOther: path.usesInterfaceType(.other)
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyNetworkPathUpdate(isSatisfied: status == .satisfied, connectionType: activeType)
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    nonisolated static func connectionType(
        isSatisfied: Bool,
        usesWiFi: Bool,
        usesCellular: Bool,
        usesOther: Bool
    ) -> ConnectionType {
        guard isSatisfied else { return .unknown }
        if usesWiFi {
            return .wifi
        }
        if usesCellular {
            return .cellular
        }
        if usesOther {
            return .unknown
        }
        return .unknown
    }

    func updateTDLibState(_ state: TDLibConnectionPhase) {
        tdlibState = state
        handleConnectivityTransition()
    }

    func applyNetworkPathUpdate(isSatisfied: Bool, connectionType: ConnectionType) {
        hasObservedPath = true
        nwPathConnected = isSatisfied
        self.connectionType = isSatisfied ? connectionType : .unknown
        handleConnectivityTransition()
    }

    private func handleConnectivityTransition() {
        let previouslyConnected = wasConnected
        let nowConnected = isConnected
        wasConnected = nowConnected
        if !previouslyConnected && nowConnected {
            onReconnected?()
        }
    }
}
