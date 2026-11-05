import XCTest
@testable import OrbitextWatch

final class TDRequestTelemetryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)

        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { date.addTimeInterval(seconds) }
        }
    }

    func testDumpExpiresIdleMethodsWithoutAnotherSend() async {
        let clock = Clock()
        let telemetry = TDRequestTelemetry(
            ringCapacity: 10, burstThreshold: 3, burstWindow: 5, now: { clock.now() }
        )
        for id in 1...3 {
            await telemetry.record(method: "oldMethod", extraId: UInt64(id), captureStack: false)
        }
        clock.advance(6)
        await telemetry.record(method: "newMethod", extraId: 4, captureStack: false)
        let dump = await telemetry.dump()
        let recentSection = dump.components(separatedBy: "## Recent methods")[1]
            .components(separatedBy: "## Burst methods")[0]
        XCTAssertFalse(recentSection.contains("oldMethod"), dump)
        XCTAssertTrue(recentSection.contains("**newMethod** recent=1"), dump)
        XCTAssertTrue(dump.contains("**oldMethod** bursts=1 recent=0 total=3"), dump)
        XCTAssertTrue(dump.contains("historical;"), dump)
        let ring = await telemetry.snapshotRing()
        XCTAssertEqual(ring.count, 4, "Expiration must retain manual-export history")
    }

    func testRecentWindowIncludesBoundaryThenExpiresWithoutNewSends() async {
        let clock = Clock()
        let telemetry = TDRequestTelemetry(
            ringCapacity: 10, burstThreshold: 3, burstWindow: 5, now: { clock.now() }
        )
        await telemetry.record(method: "GetChats", extraId: 1, captureStack: false)
        clock.advance(5)
        let atBoundary = await telemetry.dump()
        XCTAssertTrue(atBoundary.contains("**GetChats** recent=1 total=1"), atBoundary)
        clock.advance(0.001)
        let expired = await telemetry.dump()
        XCTAssertTrue(expired.contains("_no recent sends_"), expired)
        XCTAssertTrue(expired.contains("**GetChats** count=1 recent=0"), expired)
    }

    func testNewBurstAfterIdleDoesNotIncludePreviousWindow() async {
        let clock = Clock()
        let telemetry = TDRequestTelemetry(
            ringCapacity: 10, burstThreshold: 2, burstWindow: 5, now: { clock.now() }
        )
        await telemetry.record(method: "GetChats", extraId: 1, captureStack: false)
        let firstBurst = await telemetry.record(method: "GetChats", extraId: 2, captureStack: false)
        clock.advance(6)
        let afterIdle = await telemetry.record(method: "GetChats", extraId: 3, captureStack: false)
        let nextBurst = await telemetry.record(method: "GetChats", extraId: 4, captureStack: false)
        XCTAssertTrue(firstBurst)
        XCTAssertFalse(afterIdle)
        XCTAssertTrue(nextBurst)
        let dump = await telemetry.dump()
        XCTAssertTrue(dump.contains("**GetChats** bursts=2 recent=2 total=4"), dump)
    }

    func testPeriodicReportIsSilentWithoutNewSendsAndDoesNotReplayHistory() async {
        let clock = Clock()
        let telemetry = TDRequestTelemetry(
            ringCapacity: 10, burstThreshold: 3, burstWindow: 5, now: { clock.now() }
        )
        let empty = await telemetry.periodicDump()
        XCTAssertNil(empty)
        await telemetry.record(method: "GetChats", extraId: 1, captureStack: false)
        await telemetry.record(method: "GetChats", extraId: 2, captureStack: false)
        _ = await telemetry.dump() // Manual export must not consume periodic output.
        let first = await telemetry.periodicDump()
        XCTAssertTrue(first?.contains("**GetChats** new=2 recent=2") == true)
        let unchanged = await telemetry.periodicDump()
        XCTAssertNil(unchanged)
        clock.advance(6)
        let aged = await telemetry.periodicDump()
        XCTAssertNil(aged, "A newer dump timestamp is not a new send")
        await telemetry.record(method: "GetChats", extraId: 3, captureStack: false)
        let next = await telemetry.periodicDump()
        XCTAssertTrue(next?.contains("**GetChats** new=1 recent=1") == true)
        XCTAssertFalse(next?.contains("Historical trace") == true)
    }

    func testPeriodicCountsSurviveRingOverflowAndMarkOldSendsAsNotRecent() async {
        let clock = Clock()
        let telemetry = TDRequestTelemetry(
            ringCapacity: 2, burstThreshold: 3, burstWindow: 5, now: { clock.now() }
        )
        for id in 1...5 {
            await telemetry.record(method: "GetChats", extraId: UInt64(id), captureStack: false)
        }
        clock.advance(10)
        let report = await telemetry.periodicDump()
        XCTAssertTrue(report?.contains("newSends=5") == true)
        XCTAssertTrue(report?.contains("**GetChats** new=5 recent=0 last=") == true)
        let ring = await telemetry.snapshotRing()
        XCTAssertEqual(ring.count, 2)
    }

    func testResetStartsANewPeriodicReportingSession() async {
        let telemetry = TDRequestTelemetry(ringCapacity: 10, burstThreshold: 3, burstWindow: 5)
        await telemetry.record(method: "GetChats", extraId: 1, captureStack: false)
        _ = await telemetry.periodicDump()
        await telemetry.reset()
        let reset = await telemetry.periodicDump()
        XCTAssertNil(reset)
        await telemetry.record(method: "GetChats", extraId: 2, captureStack: false)
        let next = await telemetry.periodicDump()
        XCTAssertTrue(next?.contains("newSends=1") == true)
    }

    func test_record_incrementsCount() async {
        let t = TDRequestTelemetry(ringCapacity: 500, burstThreshold: 3, burstWindow: 5)
        await t.record(method: "GetChats", extraId: 1, captureStack: false)
        await t.record(method: "GetChats", extraId: 2, captureStack: false)
        let count = await t.countFor(method: "GetChats")
        XCTAssertEqual(count, 2)
    }

    func test_record_detectsBurst() async {
        let t = TDRequestTelemetry(ringCapacity: 500, burstThreshold: 3, burstWindow: 5)
        let r1 = await t.record(method: "GetChats", extraId: 1, captureStack: false)
        let r2 = await t.record(method: "GetChats", extraId: 2, captureStack: false)
        let r3 = await t.record(method: "GetChats", extraId: 3, captureStack: false)
        let r4 = await t.record(method: "GetChats", extraId: 4, captureStack: false)
        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
        XCTAssertTrue(r3)
        XCTAssertFalse(r4, "Burst logging should fire only when crossing the threshold")
    }

    func test_record_doesNotDetectBurstAcrossDifferentMethods() async {
        let t = TDRequestTelemetry(ringCapacity: 500, burstThreshold: 3, burstWindow: 5)
        _ = await t.record(method: "GetChats", extraId: 1, captureStack: false)
        _ = await t.record(method: "GetMe", extraId: 2, captureStack: false)
        let burst = await t.record(method: "GetSupergroup", extraId: 3, captureStack: false)
        XCTAssertFalse(burst)
    }

    func test_ringBuffer_respectsCapacity() async {
        let t = TDRequestTelemetry(ringCapacity: 10, burstThreshold: 100, burstWindow: 60)
        for i in 0..<25 {
            _ = await t.record(method: "Ping", extraId: UInt64(i), captureStack: false)
        }
        let ring = await t.snapshotRing()
        XCTAssertEqual(ring.count, 10)
        XCTAssertEqual(ring.first?.extraId, 15)
        XCTAssertEqual(ring.last?.extraId, 24)
    }

    func test_dump_listsTopMethodsByCount() async {
        let t = TDRequestTelemetry(ringCapacity: 500, burstThreshold: 100, burstWindow: 60)
        for _ in 0..<5 { _ = await t.record(method: "GetChats", extraId: 1, captureStack: false) }
        for _ in 0..<2 { _ = await t.record(method: "GetMe", extraId: 2, captureStack: false) }
        _ = await t.record(method: "LoadChats", extraId: 3, captureStack: false)
        let dump = await t.dump()
        XCTAssertTrue(dump.contains("GetChats"), "dump missing GetChats; got:\n\(dump)")
        XCTAssertTrue(dump.contains("## Top methods"))
        XCTAssertTrue(dump.contains("## Recent methods"))
        XCTAssertTrue(dump.contains("lastExtra=1"))
        let chatsIdx = dump.range(of: "GetChats")!.lowerBound
        let meIdx = dump.range(of: "GetMe")!.lowerBound
        XCTAssertLessThan(chatsIdx, meIdx)
    }

    func test_dump_listsBurstCountWithoutRepeatedBurstEvents() async {
        let t = TDRequestTelemetry(ringCapacity: 500, burstThreshold: 3, burstWindow: 5)
        let r1 = await t.record(method: "getUser", extraId: 1, captureStack: false)
        let r2 = await t.record(method: "getUser", extraId: 2, captureStack: false)
        let r3 = await t.record(method: "getUser", extraId: 3, captureStack: false)
        let r4 = await t.record(method: "getUser", extraId: 4, captureStack: false)
        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
        XCTAssertTrue(r3)
        XCTAssertFalse(r4)

        let dump = await t.dump()
        XCTAssertTrue(dump.contains("## Burst methods"))
        XCTAssertTrue(dump.contains("**getUser** bursts=1 recent=4 total=4 lastExtra=4"), dump)
    }
}
