import Foundation
import os

/// Records outgoing TDLib requests for diagnostic dumps. Single source of
/// truth for "how many of method X did we just send and from where".
///
/// Phase 1 only: this actor is read by a periodic dump task and by the
/// Settings "Export TDLib trace" button. It does not affect request flow.
actor TDRequestTelemetry {
    struct MethodStat {
        var count: Int
        var firstAt: Date
        var lastAt: Date
        var recentTs: [Date]
        var lastExtraId: UInt64
        var burstCount: Int
    }

    struct TraceEntry {
        let ts: Date
        let method: String
        let extraId: UInt64
        let stack: [String]
    }

    private let ringCapacity: Int
    private let burstThreshold: Int
    private let burstWindow: TimeInterval
    private let now: @Sendable () -> Date

    private var stats: [String: MethodStat] = [:]
    private var ring: [TraceEntry] = []
    private var periodicCounts: [String: Int] = [:]

    init(
        ringCapacity: Int,
        burstThreshold: Int,
        burstWindow: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ringCapacity = ringCapacity
        self.burstThreshold = burstThreshold
        self.burstWindow = burstWindow
        self.now = now
    }

    /// Record a send. Returns true if this send completes a burst
    /// (>= burstThreshold sends of `method` within `burstWindow` seconds).
    @discardableResult
    func record(method: String, extraId: UInt64, captureStack: Bool) -> Bool {
        let now = now()
        var stat = stats[method] ?? MethodStat(
            count: 0,
            firstAt: now,
            lastAt: now,
            recentTs: [],
            lastExtraId: extraId,
            burstCount: 0
        )
        stat.count += 1
        stat.lastAt = now
        stat.lastExtraId = extraId
        stat.recentTs.append(now)
        let cutoff = now.addingTimeInterval(-burstWindow)
        while let head = stat.recentTs.first, head < cutoff {
            stat.recentTs.removeFirst()
        }
        let burst = stat.recentTs.count == burstThreshold
        if burst {
            stat.burstCount += 1
        }
        stats[method] = stat

        let stack = captureStack ? Self.captureCallStack() : []
        let entry = TraceEntry(ts: now, method: method, extraId: extraId, stack: stack)
        ring.append(entry)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        return burst
    }

    func countFor(method: String) -> Int {
        stats[method]?.count ?? 0
    }

    func snapshotRing() -> [TraceEntry] { ring }

    func reset() {
        stats.removeAll()
        ring.removeAll()
        periodicCounts.removeAll()
    }

    func dump() -> String {
        let now = now()
        expireRecentSends(asOf: now)
        let topMethods = stats
            .sorted { $0.value.count > $1.value.count }
            .prefix(10)
        let recentMethods = stats
            .filter { !$0.value.recentTs.isEmpty }
            .sorted {
                if $0.value.recentTs.count == $1.value.recentTs.count {
                    return $0.value.count > $1.value.count
                }
                return $0.value.recentTs.count > $1.value.recentTs.count
            }
            .prefix(10)
        let burstMethods = stats
            .filter { $0.value.burstCount > 0 || $0.value.recentTs.count >= burstThreshold }
            .sorted {
                if $0.value.burstCount == $1.value.burstCount {
                    return $0.value.recentTs.count > $1.value.recentTs.count
                }
                return $0.value.burstCount > $1.value.burstCount
            }
            .prefix(5)
        let lastEntries = ring.suffix(50)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var out = "# TDLib Request Telemetry Dump\n"
        out += "Generated: \(fmt.string(from: now))\n\n"

        out += "## Top methods (by count)\n"
        if topMethods.isEmpty {
            out += "_no sends recorded_\n"
        } else {
            for (name, s) in topMethods {
                out += "- **\(name)** count=\(s.count) recent=\(s.recentTs.count) lastExtra=\(s.lastExtraId) first=\(fmt.string(from: s.firstAt)) last=\(fmt.string(from: s.lastAt))\n"
            }
        }
        out += "\n"

        out += "## Recent methods (last \(Int(burstWindow))s)\n"
        if recentMethods.isEmpty {
            out += "_no recent sends_\n"
        } else {
            for (name, s) in recentMethods {
                out += "- **\(name)** recent=\(s.recentTs.count) total=\(s.count) lastExtra=\(s.lastExtraId)\n"
            }
        }
        out += "\n"

        out += "## Burst methods (historical; >=\(burstThreshold) in \(Int(burstWindow))s)\n"
        if burstMethods.isEmpty {
            out += "_no recorded bursts_\n"
        } else {
            for (name, s) in burstMethods {
                out += "- **\(name)** bursts=\(s.burstCount) recent=\(s.recentTs.count) total=\(s.count) lastExtra=\(s.lastExtraId)\n"
            }
        }
        out += "\n"

        out += "## Historical trace entries (last \(lastEntries.count))\n"
        for e in lastEntries {
            out += "- \(fmt.string(from: e.ts)) `\(e.method)` extra=\(e.extraId)"
            if !e.stack.isEmpty {
                out += "\n  stack:\n"
                for line in e.stack {
                    out += "    \(line)\n"
                }
            } else {
                out += "\n"
            }
        }
        return out
    }

    /// Automatic diagnostics report each send only once. Manual exports retain
    /// the complete bounded history and do not consume this reporting cursor.
    func periodicDump() -> String? {
        let now = now()
        expireRecentSends(asOf: now)
        let changed = stats.compactMap { name, stat -> (name: String, stat: MethodStat, count: Int)? in
            let count = stat.count - (periodicCounts[name] ?? 0)
            return count > 0 ? (name, stat, count) : nil
        }.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        guard !changed.isEmpty else { return nil }
        periodicCounts = stats.mapValues(\.count)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let total = changed.reduce(0) { $0 + $1.count }
        var out = "# TDLib new sends since previous periodic report\n"
        out += "Generated: \(fmt.string(from: now)) newSends=\(total) methods=\(changed.count)\n"
        for item in changed.prefix(10) {
            out += "- **\(item.name)** new=\(item.count) recent=\(item.stat.recentTs.count) last=\(fmt.string(from: item.stat.lastAt))\n"
        }
        return out
    }

    private func expireRecentSends(asOf now: Date) {
        let cutoff = now.addingTimeInterval(-burstWindow)
        for method in Array(stats.keys) {
            stats[method]?.recentTs.removeAll { $0 < cutoff }
        }
    }

    private static func captureCallStack() -> [String] {
        let raw = Thread.callStackSymbols
        guard raw.count > 3 else { return raw }
        return Array(raw.dropFirst(3).prefix(15))
    }
}
