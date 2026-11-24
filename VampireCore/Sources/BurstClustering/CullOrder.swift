import Foundation

/// Which way time runs through a session (grid, pager, burst stacks).
public enum TimeDirection: String, Codable, Sendable, CaseIterable {
    case newestFirst
    case oldestFirst
}

/// How the user wants a session ordered.
public struct OrderSettings: Equatable, Codable, Sendable {
    public var direction: TimeDirection
    /// Lead each burst with the frame we'd bet on (a hint; never a decision).
    public var bestFirst: Bool

    public init(direction: TimeDirection = .newestFirst, bestFirst: Bool = true) {
        self.direction = direction
        self.bestFirst = bestFirst
    }
}

/// One pager position: a single photo, or a burst stacked vertically.
public struct CullStack: Equatable, Sendable {
    /// Stable identity: a burst's group ID (its earliest frame) or the
    /// photo's own ID. Survives re-clustering and re-sorting, unlike an
    /// index.
    public let id: String
    /// Display order (top of the stack first).
    public let memberIDs: [String]

    public init(id: String, memberIDs: [String]) {
        self.id = id
        self.memberIDs = memberIDs
    }

    public var isBurst: Bool { memberIDs.count > 1 }
}

/// The single source of truth for "what comes after what" in a session:
/// stack order, frame order inside bursts, and the flat sequence the grid
/// shows and the pager preloads. Everything that navigates (grid, pager,
/// auto-advance, preloading, camera prefetch priority) reads one of these
/// instead of re-deriving order — mismatched private orderings were behind
/// best-first and burst-indicator bugs.
///
/// Pure value; rebuild it whenever photos, bursts, signals or settings
/// change.
public struct CullOrder: Equatable, Sendable {
    public struct Location: Equatable, Sendable {
        public let stack: Int
        public let member: Int
    }

    public let stacks: [CullStack]
    /// Every photo, stack by stack in display order.
    public let flat: [String]
    private let locations: [String: Location]
    private let stackIndexByID: [String: Int]

    public static let empty = CullOrder(stacks: [])

    /// - Parameters:
    ///   - photos: every photo in the session with its capture time (nil
    ///     sorts as the distant past).
    ///   - bursts: burst groups (ID + members), as from `BurstClusterer`.
    ///     Single-member groups and unknown members are ignored.
    ///   - best: burst ID → the frame to lead with when `bestFirst`.
    ///   - pinned: a stack whose frame order must not change (the one on
    ///     screen): its known frames keep their order, new ones follow.
    public init(
        photos: [(id: String, date: Date?)], bursts: [(id: String, memberIDs: [String])],
        settings: OrderSettings, best: [String: String] = [:], pinned: CullStack? = nil
    ) {
        let date = Dictionary(photos.map { ($0.id, $0.date ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let newestFirst = settings.direction == .newestFirst
        // Time order with a stable tie-break, so equal timestamps never
        // shuffle between rebuilds.
        func before(_ a: String, _ b: String) -> Bool {
            let da = date[a]!
            let db = date[b]!
            if da != db { return newestFirst ? da > db : da < db }
            return newestFirst ? a > b : a < b
        }

        var burstOf: [String: Int] = [:]
        var groups: [(id: String, members: [String])] = []
        for burst in bursts {
            let members = burst.memberIDs.filter { date[$0] != nil && burstOf[$0] == nil }
            guard members.count > 1 else { continue }
            for id in members { burstOf[id] = groups.count }
            groups.append((burst.id, members))
        }

        var stacks: [(lead: String, stack: CullStack)] = []
        for group in groups {
            var members = group.members.sorted(by: before)
            let lead = members[0]  // time position of the stack, before best-first
            if let pinned, pinned.id == group.id {
                let rank = Dictionary(pinned.memberIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                members =
                    members.filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
                    + members.filter { rank[$0] == nil }
            } else if settings.bestFirst, let bestID = best[group.id],
                let index = members.firstIndex(of: bestID), index > 0
            {
                members.insert(members.remove(at: index), at: 0)
            }
            stacks.append((lead, CullStack(id: group.id, memberIDs: members)))
        }
        for photo in photos where burstOf[photo.id] == nil {
            stacks.append((photo.id, CullStack(id: photo.id, memberIDs: [photo.id])))
        }
        stacks.sort { before($0.lead, $1.lead) }
        self.init(stacks: stacks.map(\.stack))
    }

    public init(stacks: [CullStack]) {
        self.stacks = stacks
        var flat: [String] = []
        var locations: [String: Location] = [:]
        var stackIndexByID: [String: Int] = [:]
        for (s, stack) in stacks.enumerated() {
            stackIndexByID[stack.id] = s
            for (m, id) in stack.memberIDs.enumerated() {
                locations[id] = Location(stack: s, member: m)
                flat.append(id)
            }
        }
        self.flat = flat
        self.locations = locations
        self.stackIndexByID = stackIndexByID
    }

    // MARK: Lookup

    public func location(of photoID: String) -> Location? { locations[photoID] }

    public func stack(containing photoID: String) -> CullStack? {
        locations[photoID].map { stacks[$0.stack] }
    }

    public func stackIndex(ofStack stackID: String) -> Int? { stackIndexByID[stackID] }

    public func flatIndex(of photoID: String) -> Int? {
        guard let location = locations[photoID] else { return nil }
        // Members before this stack, plus the member's own position.
        var index = location.member
        for s in 0..<location.stack { index += stacks[s].memberIDs.count }
        return index
    }

    // MARK: Navigation

    /// Where rating moves you: down the burst, then on to the next stack's
    /// top frame. Past the end, wraps to the first undecided photo. Nil when
    /// nothing is left to visit.
    public func advance(from photoID: String, isUndecided: (String) -> Bool) -> String? {
        guard let location = locations[photoID] else { return firstUndecided(isUndecided) }
        let stack = stacks[location.stack]
        if location.member + 1 < stack.memberIDs.count { return stack.memberIDs[location.member + 1] }
        return advanceToNextStack(from: photoID, isUndecided: isUndecided)
    }

    /// Leaves the current stack entirely (after deciding a whole burst).
    public func advanceToNextStack(from photoID: String, isUndecided: (String) -> Bool) -> String? {
        guard let location = locations[photoID] else { return firstUndecided(isUndecided) }
        if location.stack + 1 < stacks.count { return stacks[location.stack + 1].memberIDs[0] }
        return firstUndecided(isUndecided)
    }

    public func firstUndecided(_ isUndecided: (String) -> Bool) -> String? {
        flat.first(where: isUndecided)
    }

    /// Photos within `radius` of this one in display order, nearest first
    /// (ties: ahead before behind) — what to load or fetch first.
    public func neighborhood(of photoID: String, radius: Int) -> [String] {
        guard let center = flatIndex(of: photoID) else { return [] }
        var result = [flat[center]]
        for distance in 1...max(radius, 1) {
            if center + distance < flat.count { result.append(flat[center + distance]) }
            if center - distance >= 0 { result.append(flat[center - distance]) }
        }
        return result
    }
}
