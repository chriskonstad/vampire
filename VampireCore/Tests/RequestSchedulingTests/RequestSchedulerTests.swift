import XCTest
@testable import RequestScheduling

final class RequestSchedulerTests: XCTestCase {

    func testPriorityOrdering() {
        var scheduler = RequestScheduler<String>()
        scheduler.enqueue("pf", priority: .prefetch)
        scheduler.enqueue("prev", priority: .previous)
        scheduler.enqueue("cur", priority: .current)
        scheduler.enqueue("next", priority: .next)

        XCTAssertEqual(scheduler.dequeue()?.key, "cur")
        XCTAssertEqual(scheduler.dequeue()?.key, "next")
        XCTAssertEqual(scheduler.dequeue()?.key, "prev")
        XCTAssertEqual(scheduler.dequeue()?.key, "pf")
        XCTAssertNil(scheduler.dequeue())
    }

    func testFIFOWithinTier() {
        var scheduler = RequestScheduler<Int>()
        for i in 0 ..< 5 { scheduler.enqueue(i, priority: .prefetch) }
        XCTAssertEqual(scheduler.dequeue()?.key, 0)
        XCTAssertEqual(scheduler.dequeue()?.key, 1)
    }

    func testReenqueueReplacesPriority() {
        var scheduler = RequestScheduler<String>()
        scheduler.enqueue("a", priority: .prefetch)
        scheduler.enqueue("b", priority: .next)
        scheduler.enqueue("a", priority: .current) // user scrolled to it

        XCTAssertEqual(scheduler.count, 2)
        XCTAssertEqual(scheduler.dequeue()?.key, "a")
    }

    func testCancel() {
        var scheduler = RequestScheduler<String>()
        scheduler.enqueue("a", priority: .current)
        scheduler.cancel("a")
        XCTAssertFalse(scheduler.contains("a"))
        XCTAssertNil(scheduler.dequeue())
    }

    func testGenerationInvalidation() {
        var scheduler = RequestScheduler<String>()
        scheduler.enqueue("stale1", priority: .current)
        scheduler.enqueue("stale2", priority: .prefetch)
        scheduler.advanceGeneration() // fling: everything pending is stale
        XCTAssertTrue(scheduler.isEmpty)

        scheduler.enqueue("fresh", priority: .current)
        XCTAssertEqual(scheduler.dequeue()?.key, "fresh")
    }

    func testReenqueueAfterGenerationRevalidates() {
        var scheduler = RequestScheduler<String>()
        scheduler.enqueue("a", priority: .prefetch)
        scheduler.enqueue("b", priority: .prefetch)
        // "a" is re-requested at the new position before the flush.
        scheduler.enqueue("a", priority: .current)
        scheduler.advanceGeneration()
        XCTAssertTrue(scheduler.isEmpty, "advanceGeneration drops everything older")
    }

    func testFocusConvenience() {
        var scheduler = RequestScheduler<Int>()
        scheduler.focus(current: 5, next: 6, previous: 4, prefetch: [7, 8, 3])

        XCTAssertEqual(scheduler.dequeue()?.key, 5)
        XCTAssertEqual(scheduler.dequeue()?.key, 6)
        XCTAssertEqual(scheduler.dequeue()?.key, 4)
        XCTAssertEqual(scheduler.dequeue()?.priority, .prefetch)
    }

    func testFocusDoesNotDemoteHigherPriorityViaPrefetchList() {
        var scheduler = RequestScheduler<Int>()
        scheduler.enqueue(9, priority: .next)
        scheduler.focus(current: 5, next: nil, previous: nil, prefetch: [9])
        scheduler.cancel(5)
        XCTAssertEqual(scheduler.dequeue()?.priority, .next)
    }

    func testFocusBoundaries() {
        // First and last photo: no previous / no next.
        var scheduler = RequestScheduler<Int>()
        scheduler.focus(current: 0, next: 1, previous: nil)
        XCTAssertEqual(scheduler.count, 2)
    }
}
