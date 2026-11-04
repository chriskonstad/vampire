import Foundation

/// Where the pager is: the single source of truth for the photo on screen.
/// The counter, burst indicator, ratings, preloading and camera priority all
/// derive from `currentPhotoID`, so they can't disagree.
///
/// Truth comes from the views: each burst stack reports the frame it
/// actually shows (`reportShown`). A programmatic move (rating auto-advance,
/// undo, a grid tap mid-burst) is *pending* until its stack reports landing
/// there; until then the target counts as current, so a quick second tap
/// rates the frame you're headed to. A pending move that never lands (the
/// view couldn't scroll yet) expires, and the reported frame wins again —
/// the indicator never shows a frame that isn't on screen for long.
public struct PagerPosition: Equatable, Sendable {
    public private(set) var stackID: String
    private var shown: [String: String] = [:]
    private var pending: Pending?

    private struct Pending: Equatable, Sendable {
        let stackID: String
        let photoID: String
        let since: Date
    }

    /// How long a programmatic move may go unconfirmed.
    public static let pendingLifetime: TimeInterval = 0.6

    /// Starts on a photo (a grid tap); falls back to the first stack.
    public init(photoID: String?, in order: CullOrder, now: Date = Date()) {
        if let photoID, let stack = order.stack(containing: photoID) {
            stackID = stack.id
            if stack.memberIDs.first != photoID {
                pending = Pending(stackID: stack.id, photoID: photoID, since: now)
            }
        } else {
            stackID = order.stacks.first?.id ?? ""
        }
    }

    /// The photo on screen (or being moved to).
    public func currentPhotoID(in order: CullOrder) -> String? {
        photoID(inStack: stackID, in: order)
    }

    /// The frame a stack shows — for the indicator on any page.
    public func photoID(inStack stackID: String, in order: CullOrder) -> String? {
        guard let index = order.stackIndex(ofStack: stackID) else { return nil }
        let members = order.stacks[index].memberIDs
        if let pending, pending.stackID == stackID, members.contains(pending.photoID) { return pending.photoID }
        if let shown = shown[stackID], members.contains(shown) { return shown }
        return members.first
    }

    /// A programmatic move. Returns true when it stays in the current
    /// stack (the view should scroll the stack), false when it changes
    /// stacks (the view should page; the stack lands on the frame as it
    /// appears).
    @discardableResult
    public mutating func move(to photoID: String, in order: CullOrder, now: Date = Date()) -> Bool {
        guard let stack = order.stack(containing: photoID) else { return false }
        let sameStack = stack.id == stackID
        stackID = stack.id
        if stack.memberIDs.first == photoID, !sameStack, shown[stack.id] == nil || shown[stack.id] == photoID {
            pending = nil  // a fresh stack starts at its top anyway
        } else {
            pending = Pending(stackID: stack.id, photoID: photoID, since: now)
        }
        return sameStack
    }

    /// The user paged sideways (the TabView's selection changed).
    public mutating func pageChanged(to stackID: String) {
        guard stackID != self.stackID else { return }
        self.stackID = stackID
        if pending?.stackID != stackID { pending = nil }
    }

    /// A stack's scroll view reports the frame it shows.
    public mutating func reportShown(_ photoID: String, inStack stackID: String, now: Date = Date()) {
        shown[stackID] = photoID
        guard let pending, pending.stackID == stackID else { return }
        if pending.photoID == photoID || now.timeIntervalSince(pending.since) > Self.pendingLifetime {
            self.pending = nil
        }
    }

    /// Drops a pending move that never landed (call on a timer after a
    /// move), so the indicator follows what's really on screen.
    public mutating func expirePending(now: Date = Date()) {
        if let pending, now.timeIntervalSince(pending.since) > Self.pendingLifetime { self.pending = nil }
    }

    /// Whether a stack still has a move to land (the view should scroll).
    public func pendingPhotoID(inStack stackID: String) -> String? {
        pending?.stackID == stackID ? pending?.photoID : nil
    }

    /// The order was rebuilt (new shots, re-clustering, re-sort): stay on
    /// the same photo even if its stack changed identity or position.
    public mutating func reconcile(with order: CullOrder, keeping photoID: String?) {
        if let photoID, let stack = order.stack(containing: photoID) {
            if stack.id != stackID { stackID = stack.id }
        } else if order.stackIndex(ofStack: stackID) == nil {
            stackID = order.stacks.first?.id ?? ""
        }
        shown = shown.filter { order.stackIndex(ofStack: $0.key) != nil }
    }
}
