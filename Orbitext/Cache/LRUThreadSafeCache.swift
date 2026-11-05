import Foundation

/// A generic thread-safe in-memory LRU cache.
///
/// Implemented as a hash map of keys to nodes in a doubly-linked recency
/// list, giving genuine O(1) `get` (lookup + promote), O(1) `set` (insert
/// or update), and O(1) amortized eviction. When the cache exceeds
/// `maxSize` after a `set`, the oldest 25% of entries are evicted from the
/// head of the recency list in one pass.
final class LRUThreadSafeCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        weak var prev: Node?
        var next: Node?
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var storage: [Key: Node] = [:]
    // head = least recently used; tail = most recently used.
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()
    /// nil keeps every entry: for mirrors that must stay complete.
    let maxSize: Int?

    init(maxSize: Int?) {
        self.maxSize = maxSize
    }

    /// Retrieve a cached value, or `nil` if not present.
    /// Promotes the key to most-recently-used so it survives eviction.
    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = storage[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    /// Insert or update a value. Evicts the oldest 25% when exceeding `maxSize`.
    func set(_ key: Key, _ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        if let node = storage[key] {
            node.value = value
            moveToTail(node)
            return
        }
        let node = Node(key: key, value: value)
        storage[key] = node
        appendToTail(node)
        if let maxSize, storage.count > maxSize {
            let toEvict = max(storage.count / 4, 1)
            for _ in 0..<toEvict {
                guard let oldest = head else { break }
                storage.removeValue(forKey: oldest.key)
                head = oldest.next
                head?.prev = nil
                if head == nil { tail = nil }
                oldest.next = nil
            }
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = storage.removeValue(forKey: key) else { return }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    /// Reset a session's entries and recency order together.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        head = nil
        tail = nil
    }

    /// Read a value, mutate it in-place via `transform`, and write it back.
    /// Returns the updated value, or `nil` if the key was not present.
    /// Does not promote the entry (matches prior behavior).
    @discardableResult
    func mutate(_ key: Key, _ transform: (inout Value) -> Void) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = storage[key] else { return nil }
        transform(&node.value)
        return node.value
    }

    subscript(key: Key) -> Value? {
        get { get(key) }
        set {
            if let newValue {
                set(key, newValue)
            }
        }
    }

    // MARK: - Private (must be called with lock held)

    private func moveToTail(_ node: Node) {
        guard node !== tail else { return }
        // Unlink node from its current position.
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        // Attach at tail.
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
    }

    private func appendToTail(_ node: Node) {
        if let currentTail = tail {
            currentTail.next = node
            node.prev = currentTail
        } else {
            head = node
        }
        tail = node
    }
}
