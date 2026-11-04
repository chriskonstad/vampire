import XCTest
@testable import RequestScheduling

final class WindowedLoaderTests: XCTestCase {
    typealias Loader = WindowedLoader<String, String>
    private let keys = (0 ..< 30).map { "p\($0)" }

    private func starts(_ effects: [Loader.Effect]) -> [Loader.Request] {
        effects.compactMap { if case .start(let r) = $0 { r } else { nil } }
    }

    private func cancels(_ effects: [Loader.Effect]) -> [Loader.Request] {
        effects.compactMap { if case .cancel(let r) = $0 { r } else { nil } }
    }

    /// Delivers every outstanding request (and whatever they start) as full.
    private func drain(_ loader: inout Loader, _ effects: [Loader.Effect]) {
        var queue = starts(effects)
        while let request = queue.first {
            queue.removeFirst()
            queue += starts(loader.deliver(request, image: request.key, isFinal: true, isFull: true))
        }
    }

    func testCurrentFirstThenNeighborsCappedInFlight() {
        var loader = Loader()
        let started = starts(loader.focus(on: 10, in: keys)).map(\.key)
        XCTAssertEqual(started, ["p10", "p11", "p9"])  // current, next, previous
        XCTAssertEqual(loader.inFlightCount, 3)
        XCTAssertEqual(loader.window, Set((6 ... 14).map { "p\($0)" }))
    }

    func testDrainingLoadsTheWholeWindow() {
        var loader = Loader()
        drain(&loader, loader.focus(on: 10, in: keys))
        for i in 6 ... 14 { XCTAssertTrue(loader.hasFullImage(for: "p\(i)"), "p\(i)") }
        XCTAssertEqual(loader.inFlightCount, 0)
    }

    func testWindowFramesAreNeverEvicted() {
        var loader = Loader(extraKept: 2)
        // Skim far through the list, loading everything on the way.
        for index in 0 ..< keys.count { drain(&loader, loader.focus(on: index, in: keys)) }
        for key in loader.window { XCTAssertNotNil(loader.image(for: key), key) }
        XCTAssertLessThanOrEqual(loader.storedCount, loader.window.count + 2)
    }

    func testRefocusKeepsInWindowLoadsAndCancelsTheRest() {
        var loader = Loader()
        let first = starts(loader.focus(on: 10, in: keys))  // p10 p11 p9 in flight
        let effects = loader.focus(on: 11, in: keys)
        XCTAssertTrue(cancels(effects).isEmpty)              // all still in reach
        XCTAssertTrue(first.allSatisfy { loader.isInFlight($0.key) })
        let far = loader.focus(on: 25, in: keys)
        XCTAssertEqual(Set(cancels(far).map(\.key)), Set(first.map(\.key)))
        XCTAssertEqual(starts(far).first?.key, "p25")
    }

    func testLateAnswerToAnOldRequestDoesNotClearTheNewOne() {
        var loader = Loader()
        let old = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        _ = loader.focus(on: 25, in: keys)                     // p10 cancelled
        let new = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        XCTAssertNotEqual(old.token, new.token)
        _ = loader.deliver(old, image: "stale", isFinal: true, isFull: true)
        XCTAssertTrue(loader.isInFlight("p10"))               // still waiting on `new`
    }

    func testStandInIsShownButAskedForAgain() {
        var loader = Loader()
        let request = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        _ = loader.deliver(request, image: "thumb", isFinal: true, isFull: false)
        XCTAssertEqual(loader.image(for: "p10"), "thumb")
        XCTAssertFalse(loader.hasFullImage(for: "p10"))
        // The real preview arrives upstream; the app refocuses. (Slots may
        // be busy with neighbors; then it's first in line.)
        let again = starts(loader.focus(on: 10, in: keys))
        XCTAssertTrue(again.contains { $0.key == "p10" } || loader.isQueued("p10"))
    }

    func testFinalDeliveryWithoutAnImageIsRetriedOnNextFocus() {
        var loader = Loader()
        let request = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        _ = loader.deliver(request, image: nil, isFinal: true, isFull: true)
        let again = starts(loader.focus(on: 10, in: keys))
        XCTAssertTrue(again.contains { $0.key == "p10" } || loader.isQueued("p10"))
    }

    func testDegradedThenFinal() {
        var loader = Loader()
        let request = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        _ = loader.deliver(request, image: "blurry", isFinal: false, isFull: false)
        XCTAssertTrue(loader.isInFlight("p10"))
        _ = loader.deliver(request, image: "sharp", isFinal: true, isFull: true)
        XCTAssertEqual(loader.image(for: "p10"), "sharp")
        XCTAssertFalse(loader.isInFlight("p10"))
    }

    func testLoadedFramesAreNotRefetched() {
        var loader = Loader()
        drain(&loader, loader.focus(on: 10, in: keys))
        XCTAssertTrue(starts(loader.focus(on: 11, in: keys)).allSatisfy { $0.key == "p15" })
    }

    func testViewportGrowthRefetchesTheWindow() {
        var loader = Loader()
        drain(&loader, loader.focus(on: 10, in: keys))
        loader.invalidateAll()
        XCTAssertEqual(starts(loader.focus(on: 10, in: keys)).first?.key, "p10")
    }

    func testFrameOnScreenNeverWaitsBehindNeighbors() {
        var loader = Loader()
        _ = loader.focus(on: 10, in: keys)                 // p10 p11 p9: all slots busy
        let effects = loader.focus(on: 12, in: keys)       // p12 now on screen
        XCTAssertEqual(starts(effects).first?.key, "p12")  // starts anyway
        XCTAssertTrue(loader.isInFlight("p12"))
    }

    func testRefocusingIsIdempotent() {
        var loader = Loader()
        var started: [String] = []
        for _ in 0 ..< 20 { started += starts(loader.focus(on: 10, in: keys)).map(\.key) }
        for _ in 0 ..< 20 { started += starts(loader.focus(on: 11, in: keys)).map(\.key) }
        XCTAssertEqual(started.count, Set(started).count, "duplicate starts: \(started)")
        XCTAssertLessThanOrEqual(loader.inFlightCount, loader.maxInFlight + 1)
    }

    func testFailedLoadOnScreenIsRetriedThenLeftAlone() {
        var loader = Loader(maxRetries: 2)
        var request = starts(loader.focus(on: 10, in: keys)).first { $0.key == "p10" }!
        for attempt in 1 ... 2 {
            let retry = starts(loader.deliver(request, image: nil, isFinal: true, isFull: false))
            XCTAssertEqual(retry.first?.key, "p10", "retry \(attempt)")
            request = retry.first!
        }
        XCTAssertTrue(starts(loader.deliver(request, image: nil, isFinal: true, isFull: false)).allSatisfy { $0.key != "p10" })
        XCTAssertTrue(loader.hasGivenUp(on: "p10"))
        // Moving away and back gives it a fresh try.
        _ = loader.focus(on: 20, in: keys)
        XCTAssertTrue(starts(loader.focus(on: 10, in: keys)).contains { $0.key == "p10" })
    }

    func testEvictedFrameComingBackIntoReachIsRequested() {
        var loader = Loader(extraKept: 0)
        drain(&loader, loader.focus(on: 5, in: keys))
        drain(&loader, loader.focus(on: 25, in: keys))      // p5's neighborhood dropped
        XCTAssertNil(loader.image(for: "p5"))
        XCTAssertEqual(starts(loader.focus(on: 5, in: keys)).first?.key, "p5")
    }
}
