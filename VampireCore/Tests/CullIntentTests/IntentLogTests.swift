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
        log.set(.keep, for: "a") // same verdict again
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(log.undo(), "a")
        XCTAssertNil(log.verdict(for: "a"))
        XCTAssertFalse(log.canUndo) // exactly one real mutation happened
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
        log.undo()           // b back to .reject
        log.set(.reject, for: "c")
        log.undo()           // c cleared, redoable

        let restored = IntentLog(replaying: journal)
        XCTAssertEqual(restored.verdicts, ["a": .keep, "b": .reject])
        XCTAssertTrue(restored.canRedo)
        XCTAssertTrue(restored.canUndo)

        // The restored session continues exactly where the old one left off.
        restored.redo()
        XCTAssertEqual(restored.verdict(for: "c"), .reject)
        restored.undo() // c cleared again
        restored.undo() // unwinds set(.reject, "b"); the .maybe branch was
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
