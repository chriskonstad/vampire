import XCTest
@testable import BurstClustering
@testable import RequestScheduling

/// Whole-pager behavior: scripted repros of reported bugs, then randomized
/// sessions that must keep every invariant at every step.
final class PagerSimulationTests: XCTestCase {

    private func assertHealthy(_ sim: PagerSimulator, _ context: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        let problems = sim.violations()
        XCTAssertTrue(problems.isEmpty, "\(context): \(problems.joined(separator: "; "))", file: file, line: line)
    }

    private func assertSettled(_ sim: inout PagerSimulator, _ context: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        sim.settle()
        let problems = sim.settledViolations()
        XCTAssertTrue(problems.isEmpty, "\(context): \(problems.joined(separator: "; "))", file: file, line: line)
    }

    // MARK: Scripted repros

    /// "Partway through a burst of ~17, move to the next burst, move back:
    /// the preview hangs." (Page rebuilt at its top while the pager still
    /// thought frame 9.)
    func testLeaveMidBurstAndComeBackToARebuiltPage() {
        var sim = PagerSimulator(stackSizes: [1, 17, 4, 1])
        sim.page(by: 1)
        for _ in 0 ..< 8 { sim.swipe(by: 1) }
        let frame9 = sim.current
        sim.page(by: 1)
        sim.page(by: -1, rebuilt: true)
        XCTAssertEqual(sim.current, frame9)
        assertHealthy(sim, "just back")
        assertSettled(&sim, "back mid-burst")
        XCTAssertEqual(sim.current, frame9)
    }

    /// Same, with the page still alive (not rebuilt).
    func testLeaveMidBurstAndComeBack() {
        var sim = PagerSimulator(stackSizes: [1, 17, 4, 1])
        sim.page(by: 1)
        for _ in 0 ..< 8 { sim.swipe(by: 1) }
        let frame9 = sim.current
        sim.page(by: 1)
        sim.page(by: -1)
        XCTAssertEqual(sim.current, frame9)
        assertSettled(&sim)
    }

    /// "Best pulled to the front but the scroll started where the best was."
    func testBurstReRankedOffScreenOpensOnItsNewBest() {
        var sim = PagerSimulator(stackSizes: [1, 6, 1])
        sim.page(by: 1)                 // build the burst page…
        sim.swipe(by: 2)                // …leave it on frame 3
        sim.page(by: 1)                 // off it
        let burst = sim.order.stacks[1]
        let newBest = burst.memberIDs[4]
        sim.rerank(burst: burst.id, best: newBest)
        XCTAssertEqual(sim.order.stacks[1].memberIDs.first, newBest)
        sim.page(by: -1)
        XCTAssertEqual(sim.current, newBest)
        assertSettled(&sim)
    }

    /// The burst on screen never reorders under you.
    func testBurstOnScreenStaysPinnedWhenReRanked() {
        var sim = PagerSimulator(stackSizes: [6, 1])
        sim.swipe(by: 2)
        let here = sim.current
        let before = sim.order.stacks[0].memberIDs
        sim.rerank(burst: sim.order.stacks[0].id, best: before[5])
        XCTAssertEqual(sim.order.stacks[0].memberIDs, before)
        XCTAssertEqual(sim.current, here)
        assertHealthy(sim)
    }

    /// "X and heart don't change until I move away and back": two quick
    /// ratings before the first scroll lands rate frames 1 and 2.
    func testQuickRatingsInABurstHitConsecutiveFrames() {
        var sim = PagerSimulator(stackSizes: [5, 1])
        let frames = sim.order.stacks[0].memberIDs
        sim.rate()
        XCTAssertEqual(sim.current, frames[1])  // before the scroll lands
        sim.rate()
        XCTAssertEqual(sim.verdicts.keys.sorted(), [frames[0], frames[1]].sorted())
        assertSettled(&sim)
        XCTAssertEqual(sim.current, frames[2])
    }

    /// "Flipping through enough bursts quickly hangs the best photo." Loads
    /// lag far behind the flipping and nothing is ready upstream yet.
    func testFlippingFastThroughBurstsWithSlowLoads() {
        var sim = PagerSimulator(stackSizes: Array(repeating: 12, count: 10), allReady: false)
        for _ in 0 ..< 9 {
            sim.page(by: 1, rebuilt: true)
            if !sim.outstanding.isEmpty { sim.deliver(at: sim.outstanding.count - 1) }  // a straggler
            assertHealthy(sim, "flipping")
        }
        for _ in 0 ..< 9 { sim.page(by: -1) ; assertHealthy(sim, "flipping back") }
        assertSettled(&sim, "after flipping")
    }

    /// Grid tap mid-burst lands there, and the indicator agrees.
    func testOpeningMidBurst() {
        var sim = PagerSimulator(stackSizes: [1, 10, 1])
        let target = sim.order.stacks[1].memberIDs[6]
        sim.open(at: target)
        XCTAssertEqual(sim.current, target)
        assertSettled(&sim)
        XCTAssertEqual(sim.current, target)
    }

    /// A seed scroll that can't land (view not ready) gives way to the
    /// screen instead of leaving the indicator wrong.
    func testMoveThatNeverLandsExpiresToTheScreen() {
        var sim = PagerSimulator(stackSizes: [1, 10, 1])
        sim.open(at: sim.order.stacks[1].memberIDs[6])
        sim.advanceClock(2)            // the scroll never landed…
        XCTAssertEqual(sim.current, sim.order.stacks[1].memberIDs[0])  // …so: what's shown
        assertHealthy(sim)
    }

    /// Re-sorting while open keeps you on the same photo.
    func testResortKeepsThePhoto() {
        var sim = PagerSimulator(stackSizes: [3, 1, 8, 1])
        sim.page(by: 2)
        sim.swipe(by: 3)
        let here = sim.current
        sim.setSettings(.init(direction: .oldestFirst, bestFirst: true))
        XCTAssertEqual(sim.order.stack(containing: here!)?.id, sim.position.stackID)
        assertSettled(&sim)
    }

    func testRejectBurstMovesToTheNextStack() {
        var sim = PagerSimulator(stackSizes: [6, 1, 1])
        sim.rejectBurst()
        XCTAssertEqual(sim.position.stackID, sim.order.stacks[1].id)
        assertSettled(&sim)
    }

    // MARK: Randomized sessions

    func testRandomSessionsKeepEveryInvariant() {
        for seed in 1 ... 400 {
            var rng = SplitMix64(seed: UInt64(seed))
            let sizes = (0 ..< Int.random(in: 3 ... 9, using: &rng)).map { _ in
                Bool.random(using: &rng) ? 1 : Int.random(in: 2 ... 24, using: &rng)
            }
            var sim = PagerSimulator(stackSizes: sizes, allReady: Bool.random(using: &rng))
            var log: [String] = []
            for step in 0 ..< 300 {
                let action = Int.random(in: 0 ..< 100, using: &rng)
                switch action {
                case 0 ..< 18:
                    let d = Bool.random(using: &rng) ? 1 : -1
                    log.append("swipe \(d)"); sim.swipe(by: d)
                case 18 ..< 32:
                    let d = Bool.random(using: &rng) ? 1 : -1
                    let rebuilt = Int.random(in: 0 ..< 3, using: &rng) == 0
                    let first = Bool.random(using: &rng)
                    log.append("page \(d) rebuilt:\(rebuilt) appearsFirst:\(first)")
                    sim.page(by: d, rebuilt: rebuilt, appearsFirst: first)
                case 32 ..< 44:
                    log.append("rate"); sim.rate()
                case 44 ..< 47:
                    log.append("rejectBurst"); sim.rejectBurst()
                case 47 ..< 53:
                    if let burst = sim.order.stacks.filter(\.isBurst).randomElement(using: &rng),
                       let best = burst.memberIDs.randomElement(using: &rng) {
                        log.append("rerank \(burst.id) → \(best)"); sim.rerank(burst: burst.id, best: best)
                    }
                case 53 ..< 55:
                    let settings = OrderSettings(direction: Bool.random(using: &rng) ? .newestFirst : .oldestFirst,
                                                 bestFirst: Bool.random(using: &rng))
                    log.append("sort \(settings)"); sim.setSettings(settings)
                case 55 ..< 80:
                    if !sim.outstanding.isEmpty {
                        let i = Int.random(in: 0 ..< sim.outstanding.count, using: &rng)
                        let fail = Int.random(in: 0 ..< 20, using: &rng) == 0
                        log.append("deliver \(sim.outstanding[i].key) fail:\(fail)"); sim.deliver(at: i, fail: fail)
                    }
                case 80 ..< 86:
                    if let id = sim.order.flat.randomElement(using: &rng) {
                        log.append("ready \(id)"); sim.becomeReady(id)
                    }
                case 86 ..< 94:
                    if let stackID = sim.scrolling.keys.sorted().randomElement(using: &rng) {
                        log.append("land \(stackID)"); sim.landScroll(in: stackID)
                    }
                case 94 ..< 97:
                    log.append("clock"); sim.advanceClock(1)
                default:
                    if let id = sim.order.flat.randomElement(using: &rng) {
                        log.append("open \(id)"); sim.open(at: id)
                    }
                }
                let problems = sim.violations()
                if !problems.isEmpty {
                    XCTFail("seed \(seed) step \(step): \(problems.joined(separator: "; "))\n"
                        + "stacks \(sizes)\nlast actions: \(log.suffix(12).joined(separator: " | "))")
                    break
                }
            }
            sim.settle()
            let settled = sim.settledViolations()
            XCTAssertTrue(settled.isEmpty, "seed \(seed) settled: \(settled.joined(separator: "; "))\n"
                + "last actions: \(log.suffix(12).joined(separator: " | "))")
        }
    }
}

/// Deterministic RNG so a failing seed reproduces exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
