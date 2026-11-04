import XCTest
@testable import BurstClustering

final class PagerPositionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Stacks (newest first): c | burst b3 b2 b1 | a
    private var order: CullOrder {
        CullOrder(photos: [("a", t0), ("b1", t0 + 10), ("b2", t0 + 10.1), ("b3", t0 + 10.2), ("c", t0 + 20)],
                  bursts: [("b1", ["b1", "b2", "b3"])], settings: .init(direction: .newestFirst, bestFirst: false))
    }

    func testStartsOnTheTappedPhotoMidBurst() {
        let position = PagerPosition(photoID: "b2", in: order, now: t0)
        XCTAssertEqual(position.stackID, "b1")
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")
        XCTAssertEqual(position.pendingPhotoID(inStack: "b1"), "b2")  // the view must scroll there
    }

    func testReportsBeforeLandingDontOverrideAFreshMove() {
        var position = PagerPosition(photoID: "b2", in: order, now: t0)
        // The stack appears at its top before the seed scroll runs.
        position.reportShown("b3", inStack: "b1", now: t0 + 0.05)
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")
        position.reportShown("b2", inStack: "b1", now: t0 + 0.2)
        XCTAssertNil(position.pendingPhotoID(inStack: "b1"))
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")
    }

    func testAMoveThatNeverLandsExpiresToWhatsOnScreen() {
        var position = PagerPosition(photoID: "c", in: order, now: t0)
        position.move(to: "b2", in: order, now: t0)
        position.reportShown("b3", inStack: "b1", now: t0 + 0.1)
        position.expirePending(now: t0 + 1)
        XCTAssertEqual(position.currentPhotoID(in: order), "b3")  // indicator = screen
    }

    func testSwipesUpdateTheCurrentFrame() {
        var position = PagerPosition(photoID: "b3", in: order, now: t0)
        XCTAssertNil(position.pendingPhotoID(inStack: "b1"))  // top frame: nothing to scroll
        position.reportShown("b2", inStack: "b1", now: t0 + 1)
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")
    }

    func testMoveWithinStackVersusAcross() {
        var position = PagerPosition(photoID: "b3", in: order, now: t0)
        XCTAssertTrue(position.move(to: "b2", in: order, now: t0))   // scroll the stack
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")     // at once, for quick taps
        XCTAssertFalse(position.move(to: "a", in: order, now: t0))   // page over
        XCTAssertEqual(position.stackID, "a")
    }

    func testPagingBackShowsWhatTheStackStillShows() {
        var position = PagerPosition(photoID: "b3", in: order, now: t0)
        position.reportShown("b1", inStack: "b1", now: t0)
        position.pageChanged(to: "a", in: order, now: t0)
        XCTAssertEqual(position.currentPhotoID(in: order), "a")
        position.pageChanged(to: "b1", in: order, now: t0)
        XCTAssertEqual(position.currentPhotoID(in: order), "b1")
        XCTAssertNil(position.pendingPhotoID(inStack: "b1"))  // still shown: nothing to scroll
    }

    func testPagingBackToARebuiltStackResumesMidBurst() {
        var position = PagerPosition(photoID: "b3", in: order, now: t0)
        position.reportShown("b2", inStack: "b1", now: t0)
        position.pageChanged(to: "a", in: order, now: t0)
        // The stack's page was discarded; rebuilt, it reports its top.
        position.reportShown("b3", inStack: "b1", now: t0 + 1)
        position.pageChanged(to: "b1", in: order, now: t0 + 2)
        XCTAssertEqual(position.pendingPhotoID(inStack: "b1"), "b2")  // the view scrolls back
        XCTAssertEqual(position.currentPhotoID(in: order), "b2")
    }

    func testReconcileFollowsThePhotoIntoANewStack() {
        var position = PagerPosition(photoID: "c", in: order, now: t0)
        // c becomes the newest frame of a burst led by "b1".
        let regrouped = CullOrder(photos: [("a", t0), ("b1", t0 + 10), ("c", t0 + 10.5)],
                                  bursts: [("b1", ["b1", "c"])], settings: .init(direction: .newestFirst, bestFirst: false))
        position.reconcile(from: order, to: regrouped)
        XCTAssertEqual(position.stackID, "b1")
    }

    func testAnotherBurstReRankedStartsOverAtItsNewTop() {
        // On photo "c"; the burst next door showed b2 when b1 became best.
        var position = PagerPosition(photoID: "c", in: order, now: t0)
        position.reportShown("b2", inStack: "b1", now: t0)
        let reRanked = CullOrder(photos: [("a", t0), ("b1", t0 + 10), ("b2", t0 + 10.1), ("b3", t0 + 10.2), ("c", t0 + 20)],
                                 bursts: [("b1", ["b1", "b2", "b3"])], settings: .init(direction: .newestFirst, bestFirst: true),
                                 best: ["b1": "b1"])
        XCTAssertEqual(position.reconcile(from: order, to: reRanked), ["b1"])
        XCTAssertEqual(position.photoID(inStack: "b1", in: reRanked), "b1")  // its new top, not b2
        XCTAssertEqual(position.currentPhotoID(in: reRanked), "c")
    }

    func testTheBurstOnScreenIsLeftAlone() {
        var position = PagerPosition(photoID: "b3", in: order, now: t0)
        position.reportShown("b2", inStack: "b1", now: t0)
        let appended = CullOrder(photos: [("a", t0), ("b1", t0 + 10), ("b2", t0 + 10.1), ("b3", t0 + 10.2), ("b4", t0 + 10.3), ("c", t0 + 20)],
                                 bursts: [("b1", ["b1", "b2", "b3", "b4"])], settings: .init(direction: .newestFirst, bestFirst: false))
        XCTAssertEqual(position.reconcile(from: order, to: appended), [])
        XCTAssertEqual(position.currentPhotoID(in: appended), "b2")
    }
}
