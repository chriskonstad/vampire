import Foundation

/// Priority tiers for image work, highest first:
/// the visible frame beats its neighbors beats speculative prefetch.
public enum RequestPriority: Int, Comparable, Sendable, CaseIterable {
    case prefetch = 0
    case previous = 1
    case next = 2
    case current = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pure-logic priority queue behind every image pipeline in the app
/// (pager decode, head-of-file reads, Vision indexing backfill).
///
/// Semantics:
/// - One pending request per key; re-enqueueing a key replaces its priority
///   (a prefetch that becomes the current frame jumps the queue, and vice versa).
/// - FIFO within a priority tier.
/// - `advanceGeneration()` invalidates everything enqueued before it — the
///   cheap way to flush stale work when the user flings the scroll view.
///
/// Not thread-safe by itself; callers confine it to one actor/queue.
public struct RequestScheduler<Key: Hashable> {
    private struct Pending {
        let key: Key
        var priority: RequestPriority
        var generation: UInt64
        let sequence: UInt64
    }

    private var pending: [Key: Pending] = [:]
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    /// Adds or reprioritizes. The request is tagged with the current generation.
    public mutating func enqueue(_ key: Key, priority: RequestPriority) {
        if var existing = pending[key] {
            existing.priority = priority
            existing.generation = generation // touching a key revalidates it
            pending[key] = existing
        } else {
            pending[key] = Pending(key: key, priority: priority, generation: generation, sequence: nextSequence)
            nextSequence += 1
        }
    }

    public mutating func cancel(_ key: Key) {
        pending.removeValue(forKey: key)
    }

    public func contains(_ key: Key) -> Bool {
        pending[key] != nil
    }

    /// Drops all requests enqueued before this call.
    public mutating func advanceGeneration() {
        generation += 1
        pending = pending.filter { $0.value.generation == generation }
    }

    /// Removes and returns the highest-priority, oldest-within-tier request.
    public mutating func dequeue() -> (key: Key, priority: RequestPriority)? {
        guard let best = pending.values.max(by: { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.sequence > b.sequence // older (smaller sequence) wins ties
        }) else { return nil }
        pending.removeValue(forKey: best.key)
        return (best.key, best.priority)
    }

    /// Convenience for pager-style focus: enqueues current/next/previous in
    /// one shot and demotes everything else in `window` to prefetch.
    public mutating func focus(current: Key, next: Key?, previous: Key?, prefetch: [Key] = []) {
        enqueue(current, priority: .current)
        if let next { enqueue(next, priority: .next) }
        if let previous { enqueue(previous, priority: .previous) }
        for key in prefetch where pending[key] == nil || pending[key]!.priority == .prefetch {
            enqueue(key, priority: .prefetch)
        }
    }
}
