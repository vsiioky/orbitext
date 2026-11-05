import Foundation

/// The one thread every td_send, td_execute and td_create_client_id runs on.
///
/// TDLib keeps per-thread buffers for the JSON it parses on the calling
/// thread (20 KB each) and frees them only on threads it started itself. A
/// pool thread that called into TDLib and is later retired by GCD leaks its
/// buffers for good: in the simulator, every open and close of a chat left
/// another one behind. td_receive already has its own thread in
/// TDJsonWrapper's receive loop. This thread lives as long as the process.
final class TDNativeCallThread: @unchecked Sendable {
    // @unchecked: `jobs` is only touched with `condition` held; the thread
    // marks itself in its own thread dictionary.
    static let shared = TDNativeCallThread(name: "com.orbitext.td-calls")

    private static let ownerKey = "TDNativeCallThread.owner"
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    init(name: String) {
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Queues `job`; jobs run one at a time in the order they were queued.
    func async(_ job: @escaping @Sendable () -> Void) {
        condition.withLock {
            jobs.append(job)
            condition.signal()
        }
    }

    /// Runs `job` on the thread and waits for its result. Called on the
    /// thread itself, it runs `job` in place.
    func sync<T: Sendable>(_ job: @escaping @Sendable () -> T) -> T {
        if isCurrentThread { return job() }
        let result = SyncResult<T>()
        let done = DispatchSemaphore(value: 0)
        async {
            result.value = job()
            done.signal()
        }
        done.wait()
        // The semaphore orders the write on the call thread before this read.
        guard let value = result.value else { preconditionFailure("job did not produce a value") }
        return value
    }

    private var isCurrentThread: Bool {
        (Thread.current.threadDictionary[Self.ownerKey] as? ObjectIdentifier) == ObjectIdentifier(self)
    }

    private func run() {
        Thread.current.threadDictionary[Self.ownerKey] = ObjectIdentifier(self)
        while true {
            let batch: [@Sendable () -> Void] = condition.withLock {
                while jobs.isEmpty { condition.wait() }
                defer { jobs.removeAll(keepingCapacity: true) }
                return jobs
            }
            for job in batch {
                autoreleasepool { job() }
            }
        }
    }
}

private final class SyncResult<T: Sendable>: @unchecked Sendable {
    // @unchecked: written once on the call thread before the semaphore
    // signal, read once after the wait.
    var value: T?
}
