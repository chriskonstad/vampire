import XCTest

@testable import CullIntent

final class IntentLogTests: XCTestCase {

    func testSetAndQuery() {
        let log = IntentLog()
        log.set(.keep, for: "a")
        log.set(.reject, for: "b")
        log.set(.maybe, for: "c")

        XCTAssertEqual(log.verdict(for: "a"), .keep)
        XCTAssertEqual(log.assetIDs(with: .reject), ["b"])
        XCTAssertEqual(log.counts, [.keep: 1, .reject: 1, .maybe: 1])
        XCTAssertNil(log.verdict(for: "unseen"))
    }

    func testOverwriteAndClear() {
        let log = IntentLog()
        log.set(.reject, for: "a")
        log.set(.keep, for: "a")
        XCTAssertEqual(log.verdict(for: "a"), .keep)

        log.set(nil, for: "a")
        XCTAssertNil(log.verdict(for: "a"))
        XCTAssertEqual(log.counts, [:])
    }

    func testUndoRedoRoundTrip() {
        let log = IntentLog()
        log.set(.keep, for: "a")
        log.set(.reject, for: "a")

        XCTAssertEqual(log.undo(), "a")
        XCTAssertEqual(log.verdict(for: "a"), .keep)
        XCTAssertEqual(log.undo(), "a")
        XCTAssertNil(log.verdict(for: "a"))
        XCTAssertFalse(log.canUndo)

        XCTAssertEqual(log.redo(), "a")
        XCTAssertEqual(log.verdict(for: "a"), .keep)
        XCTAssertEqual(log.redo(), "a")
        XCTAssertEqual(log.verdict(for: "a"), .reject)
        XCTAssertFalse(log.canRedo)
    }

    func testBatchUndoesAndRedoesAsOneStep() {
        let log = IntentLog()
        log.set(.keep, for: "x")
        log.set(.keep, for: "b")
        log.set([("a", .reject), ("b", .reject), ("c", .reject)])
        XCTAssertEqual(log.counts, [.keep: 1, .reject: 3])

        XCTAssertEqual(log.undo(), "a")
        XCTAssertNil(log.verdict(for: "a"))
        XCTAssertEqual(log.verdict(for: "b"), .keep)  // back to its pre-batch verdict
        XCTAssertNil(log.verdict(for: "c"))
        XCTAssertEqual(log.verdict(for: "x"), .keep)  // earlier single step untouched

        XCTAssertEqual(log.redo(), "a")
        XCTAssertEqual(log.counts, [.keep: 1, .reject: 3])
        XCTAssertFalse(log.canRedo)

        log.undo()
        XCTAssertEqual(log.undo(), "b")  // next step is the single "keep b"
        XCTAssertNil(log.verdict(for: "b"))
    }

    func testBatchSkipsNoOps() {
        var appended: [IntentRecord] = []
        let log = IntentLog()
        log.set(.reject, for: "a")
        log.onAppend = { appended.append($0) }
        log.set([("a", .reject), ("b", .reject)])
        XCTAssertEqual(appended.map(\.assetID), ["b"])
        XCTAssertNotNil(appended.first?.batchID)
    }

    func testBatchReplayRestoresGroupedUndo() {
        var journal: [IntentRecord] = []
        let log = IntentLog()
        log.onAppend = { journal.append($0) }
        log.set(.keep, for: "x")
        log.set([("a", .reject), ("b", .reject)])
        log.set([("c", .reject), ("d", .reject)])
        log.undo()  // journals one undo record per asset

        let restored = IntentLog(replaying: journal)
        XCTAssertEqual(restored.verdicts, log.verdicts)
        XCTAssertEqual(restored.redo(), "c")
        XCTAssertEqual(restored.verdict(for: "d"), .reject)
        restored.undo()
        restored.undo()  // the a/b batch, in one step
        XCTAssertNil(restored.verdict(for: "a"))
        XCTAssertNil(restored.verdict(for: "b"))
        XCTAssertEqual(restored.verdict(for: "x"), .keep)
    }

    func testNewSetClearsRedoStack() {
        let log = IntentLog()
        log.set(.keep, for: "a")
        log.undo()
        XCTAssertTrue(log.canRedo)

        log.set(.maybe, for: "b")
        XCTAssertFalse(log.canRedo)
    }

    func testNoOpSetDoesNotPolluteHistory() {
        var appended: [IntentRecord] = []
        let log = IntentLog()
        log.onAppend = { appended.append($0) }

        log.set(.keep, for: "a")
        log.set(.keep, for: "a")  // same verdict again
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(log.undo(), "a")
        XCTAssertNil(log.verdict(for: "a"))
        XCTAssertFalse(log.canUndo)  // exactly one real mutation happened
    }

    func testUndoOnEmptyLogIsNil() {
        let log = IntentLog()
        XCTAssertNil(log.undo())
        XCTAssertNil(log.redo())
    }

    func testJournalReplayReconstructsStateAndStacks() {
        var journal: [IntentRecord] = []
        let log = IntentLog()
        log.onAppend = { journal.append($0) }

        log.set(.keep, for: "a")
        log.set(.reject, for: "b")
        log.set(.maybe, for: "b")
        log.undo()  // b back to .reject
        log.set(.reject, for: "c")
        log.undo()  // c cleared, redoable

        let restored = IntentLog(replaying: journal)
        XCTAssertEqual(restored.verdicts, ["a": .keep, "b": .reject])
        XCTAssertTrue(restored.canRedo)
        XCTAssertTrue(restored.canUndo)

        // The restored session continues exactly where the old one left off.
        restored.redo()
        XCTAssertEqual(restored.verdict(for: "c"), .reject)
        restored.undo()  // c cleared again
        restored.undo()  // unwinds set(.reject, "b"); the .maybe branch was
        // discarded when set(.reject, "c") cleared redo
        XCTAssertNil(restored.verdict(for: "b"))
        XCTAssertEqual(restored.verdict(for: "a"), .keep)
    }

    func testReplayedJournalEmitsNothing() {
        var journal: [IntentRecord] = []
        let log = IntentLog()
        log.onAppend = { journal.append($0) }
        log.set(.keep, for: "a")
        log.undo()

        var emitted: [IntentRecord] = []
        let restored = IntentLog(replaying: journal)
        restored.onAppend = { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty)

        restored.redo()
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].operation, .redo)
    }

    func testRecordsCodableRoundTrip() throws {
        let record = IntentRecord(
            operation: .set, assetID: "abc-123/L0/001",
            verdict: .reject, timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let decoded = try JSONDecoder().decode(
            IntentRecord.self,
            from: try JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
    }
}

/// The Apply plan — the safety gate between culling decisions and the
/// batched deletion. PhotoKit itself is untested (no device), so every
/// invariant that must hold before `performChanges` runs lives here and is
/// pinned down with synthetic asset IDs.
final class ApplyPlanTests: XCTestCase {
    func testCameraSessionNeverMutates() {
        // The protocol is what guarantees a card session can't delete.
        XCTAssertThrowsError(
            try ApplyPlan(rejects: ["a"], keeps: [], isLibrarySession: false, dryRun: false)
        ) { error in
            XCTAssertEqual(error as? ApplyPlanError, .notALibrarySession)
        }
    }

    func testEmptyPlanRejected() {
        XCTAssertThrowsError(
            try ApplyPlan(rejects: [], keeps: [], isLibrarySession: true, dryRun: false)
        ) { error in
            XCTAssertEqual(error as? ApplyPlanError, .nothingToApply)
        }
    }

    func testDryRunNeverMutates() {
        let plan = try! ApplyPlan(rejects: ["a"], keeps: ["k"], isLibrarySession: true, dryRun: true)
        XCTAssertFalse(plan.mutatesLibrary)
    }

    func testKeepsOnlyPlanDoesNotMutate() {
        let plan = try! ApplyPlan(rejects: [], keeps: ["k"], isLibrarySession: true, dryRun: false)
        XCTAssertFalse(plan.mutatesLibrary)
        XCTAssertEqual(plan.keeps, ["k"])
    }

    func testRejectsOnlyPlanMutates() {
        let plan = try! ApplyPlan(rejects: ["a", "b"], keeps: [], isLibrarySession: true, dryRun: false)
        XCTAssertTrue(plan.mutatesLibrary)
        XCTAssertEqual(plan.rejects, ["a", "b"])
    }

    func testPlanCapturesBothBuckets() {
        let plan = try! ApplyPlan(rejects: ["a"], keeps: ["k"], isLibrarySession: true, dryRun: true)
        XCTAssertEqual(plan.rejects, ["a"])
        XCTAssertEqual(plan.keeps, ["k"])
        XCTAssertTrue(plan.isLibrarySession)
    }

    func testOverlapRejectWinsKeepsFiltered() {
        let plan = try! ApplyPlan(
            rejects: ["a", "b"], keeps: ["a", "k"], isLibrarySession: true, dryRun: false)
        XCTAssertEqual(plan.rejects, ["a", "b"])
        XCTAssertEqual(plan.keeps, ["k"])
        XCTAssertTrue(plan.mutatesLibrary)
    }

    func testOverlapFullySharedKeepsEndUpEmpty() {
        // The plan is still valid: the reject bucket alone justifies Apply.
        let plan = try! ApplyPlan(
            rejects: ["a"], keeps: ["a"], isLibrarySession: true, dryRun: false)
        XCTAssertEqual(plan.rejects, ["a"])
        XCTAssertEqual(plan.keeps, [])
        XCTAssertTrue(plan.mutatesLibrary)
    }

    func testOverlapAndDuplicatesCombined() {
        let plan = try! ApplyPlan(
            rejects: ["a", "a", "b"], keeps: ["b", "a", "k", "k"],
            isLibrarySession: true, dryRun: false)
        XCTAssertEqual(plan.rejects, ["a", "b"])
        XCTAssertEqual(plan.keeps, ["k"])
    }

    func testDuplicateRejectsDeduped() {
        let plan = try! ApplyPlan(
            rejects: ["a", "b", "a", "b", "c"], keeps: [], isLibrarySession: true,
            dryRun: false)
        XCTAssertEqual(plan.rejects, ["a", "b", "c"])
        XCTAssertTrue(plan.mutatesLibrary)
    }

    func testDuplicateKeepsDeduped() {
        let plan = try! ApplyPlan(
            rejects: [], keeps: ["k2", "k1", "k2", "k1"], isLibrarySession: true,
            dryRun: false)
        XCTAssertEqual(plan.keeps, ["k2", "k1"])
        XCTAssertFalse(plan.mutatesLibrary)
    }

    func testOrderingPreserved() {
        let plan = try! ApplyPlan(
            rejects: ["c", "a", "b"], keeps: ["k3", "k1", "k2"], isLibrarySession: true,
            dryRun: true)
        XCTAssertEqual(plan.rejects, ["c", "a", "b"])
        XCTAssertEqual(plan.keeps, ["k3", "k1", "k2"])
    }

    func testKeepsOnlyDryRunMatrix() {
        for dryRun in [true, false] {
            let plan = try! ApplyPlan(
                rejects: [], keeps: ["k"], isLibrarySession: true, dryRun: dryRun)
            XCTAssertFalse(plan.mutatesLibrary, "dryRun=\(dryRun)")
        }
    }

    func testRejectsOnlyDryRunMatrix() {
        let dry = try! ApplyPlan(
            rejects: ["a"], keeps: [], isLibrarySession: true, dryRun: true)
        XCTAssertFalse(dry.mutatesLibrary)
        let live = try! ApplyPlan(
            rejects: ["a"], keeps: [], isLibrarySession: true, dryRun: false)
        XCTAssertTrue(live.mutatesLibrary)
    }

    func testMixedPlanMutatesOnlyWhenNotDryRun() {
        let dry = try! ApplyPlan(
            rejects: ["a"], keeps: ["k"], isLibrarySession: true, dryRun: true)
        XCTAssertFalse(dry.mutatesLibrary)
        XCTAssertEqual(dry.rejects, ["a"])
        XCTAssertEqual(dry.keeps, ["k"])
        let live = try! ApplyPlan(
            rejects: ["a"], keeps: ["k"], isLibrarySession: true, dryRun: false)
        XCTAssertTrue(live.mutatesLibrary)
        XCTAssertEqual(live.rejects, ["a"])
        XCTAssertEqual(live.keeps, ["k"])
    }

    func testEmptyPlanThrowsRegardlessOfDryRun() {
        for dryRun in [true, false] {
            XCTAssertThrowsError(
                try ApplyPlan(
                    rejects: [], keeps: [], isLibrarySession: true, dryRun: dryRun)
            ) { error in
                XCTAssertEqual(error as? ApplyPlanError, .nothingToApply, "dryRun=\(dryRun)")
            }
        }
    }
}
