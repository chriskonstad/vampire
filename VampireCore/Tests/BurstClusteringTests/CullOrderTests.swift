import XCTest

@testable import BurstClustering

final class CullOrderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// a (t0), burst b1…b3 (t0+10…+10.2), c (t0+20).
    private var photos: [(id: String, date: Date?)] {
        [("a", t0), ("b1", t0 + 10), ("b2", t0 + 10.1), ("b3", t0 + 10.2), ("c", t0 + 20)]
    }
    private let bursts: [(id: String, memberIDs: [String])] = [("b1", ["b1", "b2", "b3"])]

    func testNewestFirst() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(order.stacks.map(\.id), ["c", "b1", "a"])
        XCTAssertEqual(order.stacks[1].memberIDs, ["b3", "b2", "b1"])
        XCTAssertEqual(order.flat, ["c", "b3", "b2", "b1", "a"])
    }

    func testOldestFirst() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .oldestFirst, bestFirst: false))
        XCTAssertEqual(order.stacks.map(\.id), ["a", "b1", "c"])
        XCTAssertEqual(order.flat, ["a", "b1", "b2", "b3", "c"])
    }

    func testBestFirstLeadsTheBurstButKeepsItsTimeSlot() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .oldestFirst, bestFirst: true),
            best: ["b1": "b3"])
        XCTAssertEqual(order.stacks.map(\.id), ["a", "b1", "c"])
        XCTAssertEqual(order.stacks[1].memberIDs, ["b3", "b1", "b2"])
        XCTAssertEqual(order.flat, ["a", "b3", "b1", "b2", "c"])
    }

    func testBestIgnoredWhenOff() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .oldestFirst, bestFirst: false),
            best: ["b1": "b3"])
        XCTAssertEqual(order.stacks[1].memberIDs, ["b1", "b2", "b3"])
    }

    func testPinnedStackKeepsItsOrderAndAppendsNewFrames() {
        let pinned = CullStack(id: "b1", memberIDs: ["b2", "b1", "b3"])
        var withNew = photos
        withNew.append(("b4", t0 + 10.3))
        let order = CullOrder(
            photos: withNew, bursts: [("b1", ["b1", "b2", "b3", "b4"])],
            settings: .init(direction: .newestFirst, bestFirst: true),
            best: ["b1": "b4"], pinned: pinned)
        XCTAssertEqual(order.stack(containing: "b1")?.memberIDs, ["b2", "b1", "b3", "b4"])
    }

    func testLocationsAndFlatIndex() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(order.location(of: "b2"), .init(stack: 1, member: 1))
        XCTAssertEqual(order.flatIndex(of: "b2"), 2)
        XCTAssertEqual(order.flatIndex(of: "a"), 4)
        XCTAssertEqual(order.stackIndex(ofStack: "b1"), 1)
        XCTAssertNil(order.location(of: "nope"))
    }

    func testAdvanceWalksDownTheBurstThenOnThenWraps() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .newestFirst, bestFirst: false))
        let undecided: Set<String> = ["c", "b1"]
        XCTAssertEqual(order.advance(from: "c", isUndecided: undecided.contains), "b3")
        XCTAssertEqual(order.advance(from: "b3", isUndecided: undecided.contains), "b2")
        XCTAssertEqual(order.advance(from: "b1", isUndecided: undecided.contains), "a")
        // Past the end: first undecided in display order.
        XCTAssertEqual(order.advance(from: "a", isUndecided: undecided.contains), "c")
        XCTAssertNil(order.advance(from: "a", isUndecided: { _ in false }))
    }

    func testAdvanceToNextStackSkipsTheRestOfTheBurst() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(order.advanceToNextStack(from: "b3", isUndecided: { _ in true }), "a")
    }

    func testNeighborhoodNearestFirst() {
        let order = CullOrder(
            photos: photos, bursts: bursts, settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(order.neighborhood(of: "b2", radius: 2), ["b2", "b1", "b3", "a", "c"])
        XCTAssertEqual(order.neighborhood(of: "c", radius: 1), ["c", "b3"])
    }

    func testSingleMemberAndUnknownBurstMembersIgnored() {
        let order = CullOrder(
            photos: photos, bursts: [("a", ["a"]), ("x", ["x", "c"])],
            settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertTrue(order.stacks.allSatisfy { !$0.isBurst })
        XCTAssertEqual(order.flat.count, 5)
    }

    func testEqualTimestampsAreStable() {
        let same: [(id: String, date: Date?)] = [("x", t0), ("y", t0), ("z", nil)]
        let a = CullOrder(photos: same, bursts: [], settings: .init(direction: .newestFirst, bestFirst: false))
        let b = CullOrder(
            photos: same.reversed(), bursts: [], settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(a.flat, b.flat)
        XCTAssertEqual(a.flat.last, "z")  // no date sorts as the distant past
    }
}
