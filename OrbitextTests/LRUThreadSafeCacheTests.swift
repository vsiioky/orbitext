import XCTest
@testable import OrbitextWatch

final class LRUThreadSafeCacheTests: XCTestCase {
    // MARK: - TDLib chat cache

    func testUpdateReachesAChatAnnouncedBeforeHundredsOfOthers() async {
        let service = TDLibService()
        // TDLib announces every chat once; a heavy account has far more than 200.
        for id in 1...250 {
            service.handleUpdate([
                "@type": "updateNewChat",
                "chat": ["@type": "chat", "id": id, "title": "Chat \(id)"] as [String: Any]
            ])
        }
        let received = Task { [events = service.events] () -> TDLibEvent? in
            for await event in events {
                if case .chatUpdated = event { return event }
            }
            return nil
        }

        service.handleUpdate(["@type": "updateChatTitle", "chat_id": 1, "title": "Renamed"])
        let timeout = Task { try? await Task.sleep(for: .seconds(1))
        received.cancel()
        }
        let event = await received.value
        timeout.cancel()

        guard case .chatUpdated(let chat) = event else {
            return XCTFail("The update for chat 1 was dropped: \(String(describing: event))")
        }
        XCTAssertEqual(chat.id, 1)
        XCTAssertEqual(chat.title, "Renamed")
        XCTAssertNil(service.chatCache.maxSize, "Any limit loses updates for accounts above it")
    }

    func testUnboundedCacheNeverEvicts() {
        let cache = LRUThreadSafeCache<Int, Int>(maxSize: nil)

        for i in 0..<1_000 { cache.set(i, i) }

        XCTAssertEqual(cache.count, 1_000)
        XCTAssertEqual(cache.mutate(0) { $0 += 1 }, 1, "The oldest entry must still accept updates")
    }

    // MARK: - Basic Operations

    func testSetAndGet() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        cache.set("a", 1)
        XCTAssertEqual(cache.get("a"), 1)
    }

    func testGetNonexistentReturnsNil() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        XCTAssertNil(cache.get("missing"))
    }

    func testSetOverwritesExistingValue() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        cache.set("a", 1)
        cache.set("a", 2)
        XCTAssertEqual(cache.get("a"), 2)
    }

    func testSubscriptGetAndSet() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        cache["x"] = 42
        XCTAssertEqual(cache["x"], 42)
    }

    // MARK: - Mutate

    func testMutateExistingKey() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        cache.set("a", 10)
        let result = cache.mutate("a") { $0 += 5 }
        XCTAssertEqual(result, 15)
        XCTAssertEqual(cache.get("a"), 15)
    }

    func testMutateNonexistentKeyReturnsNil() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 10)
        let result = cache.mutate("missing") { $0 += 1 }
        XCTAssertNil(result)
    }

    // MARK: - Eviction

    func testEvictionRemovesOldestEntries() {
        let cache = LRUThreadSafeCache<Int, String>(maxSize: 4)

        // Fill cache: 1, 2, 3, 4
        for i in 1...4 {
            cache.set(i, "val\(i)")
        }

        // Add 5th item → exceeds maxSize → evicts oldest 25% (1 item)
        cache.set(5, "val5")

        // Key 1 should be evicted (oldest)
        XCTAssertNil(cache.get(1))
        // Keys 2-5 should survive
        XCTAssertNotNil(cache.get(2))
        XCTAssertNotNil(cache.get(3))
        XCTAssertNotNil(cache.get(4))
        XCTAssertNotNil(cache.get(5))
    }

    func testGetPromotesKeyAndPreventsEviction() {
        let cache = LRUThreadSafeCache<Int, String>(maxSize: 4)

        // Fill: 1, 2, 3, 4
        for i in 1...4 {
            cache.set(i, "val\(i)")
        }

        // Access key 1 → promotes to most-recently-used
        _ = cache.get(1)

        // Add 5th → evicts oldest (now key 2, since 1 was promoted)
        cache.set(5, "val5")

        XCTAssertNotNil(cache.get(1), "Key 1 should survive after promotion")
        XCTAssertNil(cache.get(2), "Key 2 should be evicted as oldest")
    }

    func testSetExistingKeyPromotesAndPreventsEviction() {
        let cache = LRUThreadSafeCache<Int, String>(maxSize: 4)

        for i in 1...4 {
            cache.set(i, "val\(i)")
        }

        // Update key 1 → promotes
        cache.set(1, "updated")

        // Add 5th → evicts oldest (key 2)
        cache.set(5, "val5")

        XCTAssertEqual(cache.get(1), "updated")
        XCTAssertNil(cache.get(2))
    }

    func testEvictionWithMaxSizeOne() {
        let cache = LRUThreadSafeCache<String, Int>(maxSize: 1)
        cache.set("a", 1)
        cache.set("b", 2) // evicts "a"

        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.get("b"), 2)
    }

    // MARK: - Concurrency

    func testClearReleasesValuesAndAllowsFreshEvictionOrder() {
        let cache = LRUThreadSafeCache<Int, CacheLifetimeProbe>(maxSize: 2)
        var first: CacheLifetimeProbe? = CacheLifetimeProbe()
        var second: CacheLifetimeProbe? = CacheLifetimeProbe()
        weak let weakFirst = first
        weak let weakSecond = second
        cache.set(1, first!)
        cache.set(2, second!)
        first = nil
        second = nil

        cache.clear()

        XCTAssertNil(weakFirst)
        XCTAssertNil(weakSecond)
        XCTAssertEqual(cache.count, 0)
        cache.set(3, CacheLifetimeProbe())
        cache.set(4, CacheLifetimeProbe())
        cache.set(5, CacheLifetimeProbe())
        XCTAssertNil(cache.get(3))
        XCTAssertNotNil(cache.get(4))
        XCTAssertNotNil(cache.get(5))
    }

    func testCacheDeallocationReleasesLinkedValues() {
        var cache: LRUThreadSafeCache<Int, CacheLifetimeProbe>? = LRUThreadSafeCache(maxSize: 2)
        var value: CacheLifetimeProbe? = CacheLifetimeProbe()
        weak let reference = value
        cache?.set(1, value!)
        cache?.set(2, CacheLifetimeProbe())
        value = nil

        cache = nil

        XCTAssertNil(reference)
    }

    func testConcurrentAccess() async {
        let cache = LRUThreadSafeCache<Int, Int>(maxSize: 1000)

        await withTaskGroup(of: Void.self) { group in
            // 100 concurrent writers
            for i in 0..<100 {
                group.addTask {
                    cache.set(i, i * 10)
                }
            }
            // 100 concurrent readers
            for i in 0..<100 {
                group.addTask {
                    _ = cache.get(i)
                }
            }
            // 50 concurrent mutators
            for i in 0..<50 {
                group.addTask {
                    cache.mutate(i) { $0 += 1 }
                }
            }
        }

        // Should not crash - correctness verified by no assertion failures
        // Spot-check a few values exist
        var foundCount = 0
        for i in 0..<100 {
            if cache.get(i) != nil { foundCount += 1 }
        }
        XCTAssertGreaterThan(foundCount, 0, "At least some values should be readable after concurrent access")
    }
}

private final class CacheLifetimeProbe {}
