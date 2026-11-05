import Dispatch

/// What `MemoryPressureMonitor` asks of the system's memory pressure source,
/// so a test can stand in for it: a pressure event cannot be raised on
/// demand.
protocol MemoryPressureSource: AnyObject {
    func setHandler(_ handler: @escaping @Sendable () -> Void)
    func activate()
    func cancel()
}

/// The dispatch memory pressure source: warning and critical events, on
/// `queue`.
final class DispatchMemoryPressureSource: MemoryPressureSource {
    private let source: any DispatchSourceMemoryPressure

    init(queue: DispatchQueue = .main) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
    }

    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

/// Tells its owner, for as long as it lives, that the system runs short of
/// memory: a warning or a critical level.
///
/// watchOS has no memory warning callback of its own (there is no
/// UIApplication); a dispatch memory pressure source is how an app hears it.
/// The source reports system-wide pressure, which may come before the
/// per-process limit is reached or not at all, so it is a chance to shed
/// memory early, not a guarantee.
final class MemoryPressureMonitor {
    private let source: any MemoryPressureSource

    /// `onPressure` runs where `source` delivers its events (the main queue
    /// for the system's) for every warning and critical event.
    init(
        source: any MemoryPressureSource = DispatchMemoryPressureSource(),
        onPressure: @escaping @Sendable () -> Void
    ) {
        self.source = source
        source.setHandler(onPressure)
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
