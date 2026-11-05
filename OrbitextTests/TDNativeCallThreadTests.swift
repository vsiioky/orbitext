import Foundation
import XCTest
@testable import OrbitextWatch

/// TDLib keeps per-thread buffers for the JSON it parses on the calling
/// thread and frees them only on its own threads, so every call into it goes
/// through one thread that never exits.
final class TDNativeCallThreadTests: XCTestCase {
    func testJobsRunInOrderOnOneNamedThread() {
        let calls = TDNativeCallThread(name: "test.td-calls.order")
        let record = Recorder()
        let done = expectation(description: "all jobs ran")

        for index in 0..<50 {
            calls.async {
                record.append(index, on: Thread.current)
                if index == 49 { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(record.indices, Array(0..<50))
        XCTAssertEqual(record.threads.count, 1)
        XCTAssertEqual(record.threadNames, ["test.td-calls.order"])
    }

    func testCallsFromShortLivedThreadsAllRunOnTheSameThread() {
        let calls = TDNativeCallThread(name: "test.td-calls.many")
        let record = Recorder()
        let finished = DispatchSemaphore(value: 0)

        // Pool threads come and go; TDLib must only ever see one.
        for index in 0..<20 {
            Thread {
                let value = calls.sync { () -> Int in
                    record.append(index, on: Thread.current)
                    return index * 2
                }
                XCTAssertEqual(value, index * 2)
                finished.signal()
            }.start()
        }
        for _ in 0..<20 { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }

        XCTAssertEqual(record.indices.sorted(), Array(0..<20))
        XCTAssertEqual(record.threads.count, 1)
    }

    func testSyncFromTheCallThreadDoesNotWaitForItself() {
        let calls = TDNativeCallThread(name: "test.td-calls.nested")
        let done = expectation(description: "nested call returned")

        calls.async {
            XCTAssertEqual(calls.sync { 7 }, 7)
            done.fulfill()
        }

        wait(for: [done], timeout: 2)
    }
}

private final class Recorder: @unchecked Sendable {
    // @unchecked: every access holds `lock`.
    private let lock = NSLock()
    private var storedIndices: [Int] = []
    private var storedThreads: Set<ObjectIdentifier> = []
    private var storedNames: Set<String> = []

    func append(_ index: Int, on thread: Thread) {
        lock.withLock {
            storedIndices.append(index)
            storedThreads.insert(ObjectIdentifier(thread))
            storedNames.insert(thread.name ?? "")
        }
    }

    var indices: [Int] { lock.withLock { storedIndices } }
    var threads: Set<ObjectIdentifier> { lock.withLock { storedThreads } }
    var threadNames: Set<String> { lock.withLock { storedNames } }
}
