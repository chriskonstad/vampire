import Foundation

@testable import BurstClustering
@testable import RequestScheduling

/// Drives the pager's real logic — `CullOrder`, `PagerPosition` and the
/// `WindowedLoader` core — the way the app does, against a simulated view
/// and image source, so whole-pager behavior is testable without SwiftUI.
///
/// The simulated parts follow the contracts the app relies on:
/// - Each burst page's scroll view shows one frame and reports it
///   (`onScrollTargetVisibilityChange`). Pages can be thrown away by the
///   paged TabView and rebuilt at their top frame.
/// - Programmatic scrolls land later (an animation), not instantly.
/// - The image source answers in any order; until a frame's real preview
///   exists upstream (camera fetch) it answers with a stand-in.
struct PagerSimulator {
    typealias Loader = WindowedLoader<String, String>

    struct Photo {
        let id: String
        let date: Date
    }

    private(set) var photos: [Photo]
    private(set) var bursts: [(id: String, memberIDs: [String])]
    var best: [String: String] = [:]
    /// Oldest first, so stacks appear in the order `stackSizes` lists them.
    var settings = OrderSettings(direction: .oldestFirst, bestFirst: true)

    private(set) var order: CullOrder
    private(set) var position: PagerPosition
    private(set) var loader = Loader()
    private(set) var now = Date(timeIntervalSince1970: 0)
    private(set) var verdicts: [String: Bool] = [:]  // decided?

    /// The frame each built burst page's scroll view shows. No entry = the
    /// page isn't built (it'll show its top when it is).
    private(set) var viewShown: [String: String] = [:]
    /// Programmatic scrolls still animating: stack → target.
    private(set) var scrolling: [String: String] = [:]
    /// Requests the image source hasn't answered yet.
    private(set) var outstanding: [Loader.Request] = []
    /// Frames whose real preview exists upstream (else: stand-in only).
    var upstreamReady: Set<String> = []

    /// `bursts` sizes, e.g. [1, 4, 1, 17, 1]: 1 = a single photo.
    init(stackSizes: [Int], allReady: Bool = true) {
        var photos: [Photo] = []
        var bursts: [(String, [String])] = []
        var t: TimeInterval = 0
        for (s, size) in stackSizes.enumerated() {
            var members: [String] = []
            for f in 0..<size {
                let id = "s\(s)f\(f)"
                photos.append(Photo(id: id, date: Date(timeIntervalSince1970: t)))
                members.append(id)
                t += 0.1
            }
            if size > 1 { bursts.append((members[0], members)) }
            t += 30
        }
        self.photos = photos
        self.bursts = bursts
        if allReady { upstreamReady = Set(photos.map(\.id)) }
        let order = CullOrder(
            photos: photos.map { ($0.id, $0.date) }, bursts: bursts,
            settings: settings, best: [:])
        self.order = order
        position = PagerPosition(photoID: order.flat.first, in: order, now: now)
        appear(position.stackID)
        focusLoader()
    }

    // MARK: Queries

    var current: String? { position.currentPhotoID(in: order) }
    var currentStack: CullStack? { order.stackIndex(ofStack: position.stackID).map { order.stacks[$0] } }

    func stack(ofStackID id: String) -> CullStack? { order.stackIndex(ofStack: id).map { order.stacks[$0] } }

    // MARK: User actions (as PagerView performs them)

    /// Opens the pager on a photo (grid tap).
    mutating func open(at photoID: String) {
        position = PagerPosition(photoID: photoID, in: order, now: now)
        viewShown = [:]
        scrolling = [:]
        appear(position.stackID)
        focusLoader()
    }

    /// A vertical swipe in the current burst.
    mutating func swipe(by delta: Int) {
        guard let stack = currentStack, stack.isBurst else { return }
        let shown = viewShown[stack.id] ?? stack.memberIDs[0]
        let index = stack.memberIDs.firstIndex(of: shown) ?? 0
        let target = min(max(index + delta, 0), stack.memberIDs.count - 1)
        scrolling[stack.id] = nil
        show(stack.memberIDs[target], in: stack.id)
        focusLoader()
    }

    /// A horizontal page change. `rebuilt`: the TabView had discarded the
    /// destination page; `appearsFirst`: the page builds mid-swipe, before
    /// the selection change is handled (the usual order).
    mutating func page(by delta: Int, rebuilt: Bool = false, appearsFirst: Bool = true) {
        let index = order.stackIndex(ofStack: position.stackID) ?? 0
        let target = min(max(index + delta, 0), order.stacks.count - 1)
        guard target != index else { return }
        let stackID = order.stacks[target].id
        if rebuilt {
            viewShown[stackID] = nil
            scrolling[stackID] = nil
        }
        if appearsFirst { appear(stackID) }
        position.pageChanged(to: stackID, in: order, now: now)
        if let pending = position.pendingPhotoID(inStack: stackID) { scrolling[stackID] = pending }
        if !appearsFirst { appear(stackID) }
        focusLoader()
    }

    /// Rates the current photo and advances (PagerView.ratingButton).
    mutating func rate() {
        guard let current else { return }
        verdicts[current] = true
        if let next = order.advance(from: current, isUndecided: { self.verdicts[$0] == nil }) { go(to: next) }
        focusLoader()
    }

    /// Rejects the rest of the burst and moves on (PagerView.rejectBurst).
    mutating func rejectBurst() {
        guard let stack = currentStack, let current else { return }
        for id in stack.memberIDs { verdicts[id] = true }
        if let next = order.advanceToNextStack(from: current, isUndecided: { self.verdicts[$0] == nil }) {
            go(to: next)
        }
        focusLoader()
    }

    /// New signals re-rank a burst (AppModel.rebuildOrder, pinning the
    /// burst on screen) and the pager reconciles (PagerView.onChange).
    mutating func rerank(burst burstID: String, best bestID: String) {
        best[burstID] = bestID
        rebuildOrder(pinning: true)
    }

    mutating func setSettings(_ settings: OrderSettings) {
        self.settings = settings
        rebuildOrder(pinning: false)
    }

    // MARK: World events

    /// The image source answers one outstanding request.
    mutating func deliver(at index: Int, fail: Bool = false) {
        guard outstanding.indices.contains(index) else { return }
        let request = outstanding.remove(at: index)
        let ready = upstreamReady.contains(request.key)
        let image: String? = fail ? nil : (ready ? "full:\(request.key)" : "thumb:\(request.key)")
        apply(loader.deliver(request, image: image, isFinal: true, isFull: ready && !fail))
    }

    /// A camera frame lands upstream; the app bumps imageRevision → refocus.
    mutating func becomeReady(_ photoID: String) {
        upstreamReady.insert(photoID)
        focusLoader()
    }

    /// A programmatic scroll animation finishes.
    mutating func landScroll(in stackID: String) {
        guard let target = scrolling.removeValue(forKey: stackID) else { return }
        show(target, in: stackID)
        focusLoader()
    }

    mutating func advanceClock(_ seconds: TimeInterval) {
        now += seconds
        position.expirePending(now: now)
        focusLoader()
    }

    /// Lets everything finish: scrolls land, frames arrive, loads complete.
    mutating func settle() {
        for stackID in Array(scrolling.keys) { landScroll(in: stackID) }
        upstreamReady = Set(photos.map(\.id))
        advanceClock(5)
        var guardCount = 0
        while !outstanding.isEmpty, guardCount < 10_000 {
            deliver(at: 0)
            guardCount += 1
        }
    }

    // MARK: Internals (mirroring PagerView / AppModel)

    private mutating func go(to photoID: String) {
        guard let stack = order.stack(containing: photoID) else { return }
        let within = stack.id == position.stackID
        position.move(to: photoID, in: order, now: now)
        if !within { appear(stack.id) }
        if let pending = position.pendingPhotoID(inStack: stack.id) { scrolling[stack.id] = pending }
    }

    /// A page comes on screen: built at its top if it wasn't, then (as
    /// PagerView's onAppear) scrolled to a pending move.
    private mutating func appear(_ stackID: String) {
        guard let stack = stack(ofStackID: stackID), stack.isBurst else { return }
        if viewShown[stackID] == nil { show(stack.memberIDs[0], in: stackID) }
        if let pending = position.pendingPhotoID(inStack: stackID) { scrolling[stackID] = pending }
    }

    private mutating func show(_ photoID: String, in stackID: String) {
        viewShown[stackID] = photoID
        position.reportShown(photoID, inStack: stackID, now: now)
    }

    private mutating func rebuildOrder(pinning: Bool) {
        let old = order
        let pinned = pinning ? current.flatMap { order.stack(containing: $0) } : nil
        order = CullOrder(
            photos: photos.map { ($0.id, $0.date) }, bursts: bursts,
            settings: settings, best: best, pinned: pinned)
        for stackID in position.reconcile(from: old, to: order) {
            // PagerView.topResets: built pages scroll back to their top.
            if viewShown[stackID] != nil, let top = stack(ofStackID: stackID)?.memberIDs.first {
                scrolling[stackID] = nil
                show(top, in: stackID)
            }
        }
        if !pinning {
            // A re-sort while open re-lays every page out.
            viewShown = [:]
            scrolling = [:]
            appear(position.stackID)
        }
        focusLoader()
    }

    private mutating func focusLoader() {
        guard let current, let index = order.flatIndex(of: current) else { return }
        apply(loader.focus(on: index, in: order.flat))
    }

    private mutating func apply(_ effects: [Loader.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let request): outstanding.append(request)
            case .cancel(let request): outstanding.removeAll { $0 == request }
            }
        }
    }

    // MARK: Invariants

    /// Problems with the current state; empty when healthy.
    func violations() -> [String] {
        var problems: [String] = []
        guard let stack = currentStack else { return ["no current stack \(position.stackID)"] }
        guard let current else { return ["no current photo"] }
        if !stack.memberIDs.contains(current) { problems.append("current \(current) not in its stack") }
        if !loader.window.contains(current) { problems.append("current \(current) outside the loader window") }
        if loader.image(for: current) == nil, !loader.isInFlight(current), !loader.isQueued(current),
            !loader.hasGivenUp(on: current)
        {
            problems.append("current \(current) neither loaded nor requested (hang)")
        }
        if loader.storedCount > loader.window.count + loader.extraKept {
            problems.append("holding \(loader.storedCount) images (window \(loader.window.count))")
        }
        // The indicator shows the screen unless a move is still on its way.
        if stack.isBurst, position.pendingPhotoID(inStack: stack.id) == nil,
            let shown = viewShown[stack.id], shown != current
        {
            problems.append("indicator says \(current), screen shows \(shown)")
        }
        return problems
    }

    /// After `settle()`: everything in reach is loaded for real.
    func settledViolations() -> [String] {
        var problems = violations()
        for key in loader.window where !loader.hasFullImage(for: key) {
            problems.append("\(key) in reach but not loaded after settling")
        }
        if let stack = currentStack, stack.isBurst, viewShown[stack.id] != current {
            problems.append("settled on \(current ?? "nil") but screen shows \(viewShown[stack.id] ?? "nil")")
        }
        return problems
    }
}
