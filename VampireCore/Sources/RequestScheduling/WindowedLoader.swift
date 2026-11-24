import Foundation

/// The decision logic behind the pager's image loading, with no UIKit and no
/// I/O: which frames are in reach, what to fetch next, what to keep, what to
/// cancel, what to re-request. The app wrapper (`PagerImageLoader`) carries
/// out the effects against a real image provider; tests drive it directly.
///
/// Rules (each one is a past bug):
/// - Frames in the window (±`radius` around the current one) are never
///   dropped. (An NSCache evicted the frame on screen under memory
///   pressure; nothing re-asked for it, so it sat on the spinner.)
/// - Refocusing keeps loads that are still in the window and cancels only
///   the ones that left it. (Restarting everything on every refocus starved
///   the frame on screen.)
/// - A completion is matched to its request by token, so a late answer to
///   an old request can't clear a newer one for the same frame.
/// - A stand-in (e.g. a camera thumbnail) is shown but not "full", so the
///   next focus asks again; a final delivery with no image isn't full either.
/// - Priority queue, nearest first: current > next > previous > the rest
///   of the window; at most `maxInFlight` loads at once — except the frame
///   on screen, which always starts at once (it never waits behind
///   neighbors).
/// - Idempotent: one request per frame at a time, however often the pager
///   refocuses; re-focusing only reprioritizes.
/// - A load that fails (final answer, no image) is retried — the frame on
///   screen first — up to `maxRetries` times, then waits for the next
///   change (a failed load used to leave the frame on the spinner).
public struct WindowedLoader<Key: Hashable, Image> {
    public struct Request: Hashable {
        public let key: Key
        public let token: Int
    }

    public enum Effect {
        case start(Request)
        case cancel(Request)
    }

    public let radius: Int
    public let maxInFlight: Int
    /// Images kept beyond the window, most recent first (quick back-swipes).
    public let extraKept: Int
    public let maxRetries: Int

    public private(set) var window: Set<Key> = []
    private var images: [Key: Image] = [:]
    private var recent: [Key] = []
    private var full: Set<Key> = []
    private var inFlight: [Key: Int] = [:]
    private var scheduler = RequestScheduler<Key>()
    private var nextToken = 0
    private var current: Key?
    private var failures: [Key: Int] = [:]

    public init(radius: Int = 4, maxInFlight: Int = 3, extraKept: Int = 6, maxRetries: Int = 2) {
        self.radius = radius
        self.maxInFlight = maxInFlight
        self.extraKept = extraKept
        self.maxRetries = maxRetries
    }

    // MARK: Queries

    public func image(for key: Key) -> Image? { images[key] }
    public func hasFullImage(for key: Key) -> Bool { images[key] != nil && full.contains(key) }
    public func isInFlight(_ key: Key) -> Bool { inFlight[key] != nil }
    public func isQueued(_ key: Key) -> Bool { scheduler.contains(key) }
    public var inFlightCount: Int { inFlight.count }
    /// Failed more than `maxRetries` times in a row; retried on the next
    /// focus change rather than in a loop.
    public func hasGivenUp(on key: Key) -> Bool { (failures[key] ?? 0) > maxRetries }
    public var storedCount: Int { images.count }

    // MARK: Events

    /// The pager moved (or new images became available upstream): the
    /// window follows `keys[index]`.
    public mutating func focus(on index: Int, in keys: [Key]) -> [Effect] {
        guard keys.indices.contains(index) else { return [] }
        let range = max(0, index - radius)...min(keys.count - 1, index + radius)
        if current != keys[index] { failures = [:] }  // moving on: give failed frames a fresh try
        current = keys[index]
        window = Set(range.map { keys[$0] })
        var effects: [Effect] = []
        for (key, token) in inFlight where !window.contains(key) {
            effects.append(.cancel(Request(key: key, token: token)))
            inFlight[key] = nil
        }
        trim()
        scheduler.advanceGeneration()
        scheduler.focus(
            current: keys[index],
            next: index + 1 < keys.count ? keys[index + 1] : nil,
            previous: index > 0 ? keys[index - 1] : nil,
            prefetch: range.filter { abs($0 - index) > 1 }.map { keys[$0] }
        )
        return effects + pump()
    }

    /// An answer to a request. `isFinal` false = a degraded image that a
    /// better one will follow; `isFull` = the provider now has the real
    /// preview (not a stand-in).
    public mutating func deliver(_ request: Request, image: Image?, isFinal: Bool, isFull: Bool) -> [Effect] {
        let key = request.key
        if let image { store(image, for: key) }
        guard isFinal else { return [] }
        let isCurrentRequest = inFlight[key] == request.token
        if isFull, images[key] != nil { full.insert(key) }
        if isCurrentRequest { inFlight[key] = nil }
        if image != nil {
            failures[key] = nil
        } else if isCurrentRequest, images[key] == nil, window.contains(key) {
            failures[key, default: 0] += 1
            if failures[key]! <= maxRetries {
                scheduler.enqueue(key, priority: key == current ? .current : .prefetch)
            }
        }
        return pump()
    }

    /// The viewport grew: everything needs the sharper size.
    public mutating func invalidateAll() {
        full.removeAll()
    }

    // MARK: Internals

    private func needsLoad(_ key: Key) -> Bool {
        window.contains(key) && inFlight[key] == nil && !(full.contains(key) && images[key] != nil)
            && !hasGivenUp(on: key)
    }

    private mutating func pump() -> [Effect] {
        var effects: [Effect] = []
        // The frame on screen never waits for a free slot.
        if let current, scheduler.contains(current), needsLoad(current) {
            scheduler.cancel(current)
            effects.append(start(current))
        }
        while inFlight.count < maxInFlight, let next = scheduler.dequeue() {
            guard needsLoad(next.key) else { continue }
            effects.append(start(next.key))
        }
        return effects
    }

    private mutating func start(_ key: Key) -> Effect {
        nextToken += 1
        inFlight[key] = nextToken
        return .start(Request(key: key, token: nextToken))
    }

    private mutating func store(_ image: Image, for key: Key) {
        images[key] = image
        recent.removeAll { $0 == key }
        recent.append(key)
        trim()
    }

    /// Every window frame stays; beyond that, the most recent `extraKept`.
    private mutating func trim() {
        var extras = 0
        for key in recent.reversed() where !window.contains(key) {
            extras += 1
            if extras > extraKept {
                images[key] = nil
                full.remove(key)
            }
        }
        recent.removeAll { images[$0] == nil }
    }
}
