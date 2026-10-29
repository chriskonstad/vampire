import XCTest
import GRDB
import SonyMakerNotes
import CullIntent
@testable import VampireIndex

final class IndexStoreTests: XCTestCase {
    var store: IndexStore!

    override func setUpWithError() throws {
        store = try IndexStore() // in-memory
    }

    func record(_ id: String, date: TimeInterval = 0, indexed: Bool = false) -> AssetIndexRecord {
        var record = AssetIndexRecord(
            assetID: id,
            creationDate: Date(timeIntervalSince1970: 1_750_000_000 + date),
            pixelWidth: 9504,
            pixelHeight: 6336,
            isRAW: true,
            indexedAt: indexed ? Date(timeIntervalSince1970: 1_750_100_000) : nil
        )
        if indexed { record.indexVersion = IndexStore.currentIndexVersion }
        return record
    }

    // MARK: - Asset round-trips

    func testUpsertAndFetchRoundTrip() throws {
        var input = record("asset-1", indexed: true)
        input.cameraModel = "ILCE-7RM5"
        input.focusImageWidth = 9504
        input.focusImageHeight = 6336
        input.focusX = 4000
        input.focusY = 3000
        input.featurePrint = [0.25, -1.5, 3.0]
        input.bestFaceQuality = 0.87
        input.faceCount = 2

        try store.upsert(input)
        let fetched = try XCTUnwrap(try store.asset(id: "asset-1"))

        XCTAssertEqual(fetched, input)
        XCTAssertEqual(
            fetched.focusLocation,
            FocusLocation(imageWidth: 9504, imageHeight: 6336, x: 4000, y: 3000)
        )
        XCTAssertEqual(fetched.featurePrint, [0.25, -1.5, 3.0])
    }

    func testUpsertOverwrites() throws {
        try store.upsert(record("a"))
        var updated = record("a", indexed: true)
        updated.faceCount = 3
        try store.upsert(updated)

        XCTAssertEqual(try store.asset(id: "a")?.faceCount, 3)
        XCTAssertEqual(try store.allAssets().count, 1)
    }

    func testAllAssetsOrderedByCreationDate() throws {
        try store.upsert([record("later", date: 100), record("earlier", date: 0)])
        XCTAssertEqual(try store.allAssets().map(\.assetID), ["earlier", "later"])
    }

    func testIndexedAssetIDsForResume() throws {
        try store.upsert([record("done", indexed: true), record("pending")])
        XCTAssertEqual(try store.indexedAssetIDs(), ["done"])

        // Rows from an older extraction pipeline re-index automatically.
        var stale = record("stale", indexed: true)
        stale.indexVersion = IndexStore.currentIndexVersion - 1
        try store.upsert(stale)
        XCTAssertEqual(try store.indexedAssetIDs(), ["done"])
        XCTAssertEqual(try store.indexedAssetIDs(minimumVersion: 0), ["done", "stale"])
    }

    // MARK: - Faces

    func testFacesReplaceAndQualityOrdering() throws {
        try store.upsert(record("a", indexed: true))
        try store.replaceFaces([
            FaceRecord(assetID: "a", x: 0.1, y: 0.1, width: 0.2, height: 0.2, captureQuality: 0.3),
            FaceRecord(assetID: "a", x: 0.5, y: 0.5, width: 0.2, height: 0.2, captureQuality: 0.9),
        ], forAsset: "a")

        let faces = try store.faces(forAsset: "a")
        XCTAssertEqual(faces.map(\.captureQuality), [0.9, 0.3])

        // Re-index replaces rather than accumulates.
        try store.replaceFaces(
            [FaceRecord(assetID: "a", x: 0, y: 0, width: 0.1, height: 0.1, captureQuality: 0.5)],
            forAsset: "a"
        )
        XCTAssertEqual(try store.faces(forAsset: "a").count, 1)
    }

    func testFacesByQualityAcrossAssets() throws {
        try store.upsert([record("a", indexed: true), record("b", indexed: true)])
        try store.replaceFaces(
            [FaceRecord(assetID: "a", x: 0, y: 0, width: 0.1, height: 0.1, captureQuality: 0.4)],
            forAsset: "a"
        )
        try store.replaceFaces(
            [FaceRecord(assetID: "b", x: 0, y: 0, width: 0.1, height: 0.1, captureQuality: 0.95)],
            forAsset: "b"
        )

        let top = try store.facesByQuality(limit: 1)
        XCTAssertEqual(top.first?.assetID, "b")
    }

    func testDeleteCascadesFaces() throws {
        try store.upsert(record("a", indexed: true))
        try store.replaceFaces(
            [FaceRecord(assetID: "a", x: 0, y: 0, width: 0.1, height: 0.1, captureQuality: 0.5)],
            forAsset: "a"
        )
        try store.deleteAssets(ids: ["a"])
        XCTAssertTrue(try store.faces(forAsset: "a").isEmpty)
        XCTAssertNil(try store.asset(id: "a"))
    }

    // MARK: - Sessions

    func testSessionCreateListResume() throws {
        let early = try store.createSession(
            name: "Beach", assetIDs: ["a", "b"],
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let late = try store.createSession(
            name: "Wedding", assetIDs: ["c"],
            createdAt: Date(timeIntervalSince1970: 1_750_100_000)
        )

        XCTAssertEqual(try store.allSessions().map(\.name), ["Wedding", "Beach"])
        XCTAssertEqual(Set(try store.assetIDs(inSession: early.id)), ["a", "b"])

        // Reopening an old session moves it to the top of the resume list.
        try store.markSessionOpened(id: early.id, at: Date(timeIntervalSince1970: 1_750_200_000))
        XCTAssertEqual(try store.allSessions().map(\.name), ["Beach", "Wedding"])
        _ = late
    }

    func testSessionKindPersistsAndDefaultsToLibrary() throws {
        let library = try store.createSession(name: "Beach", assetIDs: ["a"])
        let camera = try store.createSession(name: "A7RV", assetIDs: ["camera:1-1-1"], kind: .camera)
        let byID = Dictionary(uniqueKeysWithValues: try store.allSessions().map { ($0.id, $0.kind) })
        XCTAssertEqual(byID[library.id], .library)
        XCTAssertEqual(byID[camera.id], .camera)
        XCTAssertEqual(try store.sessionSummaries().first { $0.id == camera.id }?.record.kind, .camera)
    }

    func testSessionStateIsIsolatedPerSession() throws {
        let s1 = try store.createSession(name: "One", assetIDs: ["a", "b"])
        let s2 = try store.createSession(name: "Two", assetIDs: ["a", "b"])

        // Same asset, different verdicts in different sessions.
        let log1 = try store.makeIntentLog(forSession: s1.id)
        log1.set(.reject, for: "a")
        let log2 = try store.makeIntentLog(forSession: s2.id)
        log2.set(.keep, for: "a")

        XCTAssertEqual(try store.makeIntentLog(forSession: s1.id).verdict(for: "a"), .reject)
        XCTAssertEqual(try store.makeIntentLog(forSession: s2.id).verdict(for: "a"), .keep)

        // Same assets, different burst slicing per session.
        try store.assignBurstGroups(["a": "a", "b": "a"], inSession: s1.id)
        try store.assignBurstGroups(["a": nil, "b": nil], inSession: s2.id)
        let summaries = try store.sessionSummaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.assetCount), [2, 2])
    }

    func testIntentLogResumesAcrossRelaunch() throws {
        let session = try store.createSession(name: "Shoot", assetIDs: ["a", "b", "c"])

        // Sitting 1: cull a few frames.
        let log1 = try store.makeIntentLog(forSession: session.id)
        log1.set(.reject, for: "a")
        log1.set(.keep, for: "b")
        log1.set(.maybe, for: "c")
        log1.undo() // c cleared

        // Sitting 2 (relaunch): same store, same session.
        let log2 = try store.makeIntentLog(forSession: session.id)
        XCTAssertEqual(log2.verdicts, ["a": .reject, "b": .keep])
        XCTAssertTrue(log2.canRedo)
        log2.redo()
        XCTAssertEqual(log2.verdict(for: "c"), .maybe)
    }

    func testDeleteSessionRemovesMembershipAndJournalOnly() throws {
        try store.upsert(record("a", indexed: true))
        let session = try store.createSession(name: "Gone", assetIDs: ["a"])
        try store.makeIntentLog(forSession: session.id).set(.reject, for: "a")

        try store.deleteSession(id: session.id)
        XCTAssertTrue(try store.allSessions().isEmpty)
        XCTAssertTrue(try store.assetIDs(inSession: session.id).isEmpty)
        XCTAssertTrue(try store.loadIntentRecords(forSession: session.id).isEmpty)
        // The shared asset index survives.
        XCTAssertNotNil(try store.asset(id: "a"))
    }

    /// Shots that left the camera card drop their decisions; the rest of the
    /// session's journal — including other sessions' — is untouched.
    func testRemoveIntentsForAssetsInSession() throws {
        let card = try store.createSession(name: "Card", assetIDs: ["a", "b"], kind: .camera)
        let other = try store.createSession(name: "Other", assetIDs: ["a"])
        let cardLog = try store.makeIntentLog(forSession: card.id)
        cardLog.set(.keep, for: "a")
        cardLog.set(.reject, for: "b")
        try store.makeIntentLog(forSession: other.id).set(.keep, for: "a")

        try store.removeIntents(forAssets: ["a"], inSession: card.id)

        let replayed = try store.makeIntentLog(forSession: card.id)
        XCTAssertNil(replayed.verdict(for: "a"))
        XCTAssertEqual(replayed.verdict(for: "b"), .reject)
        XCTAssertEqual(try store.makeIntentLog(forSession: other.id).verdict(for: "a"), .keep)
    }

    func testRenameSession() throws {
        let session = try store.createSession(name: "Untitled", assetIDs: ["a"])
        try store.renameSession(id: session.id, name: "Tide pools")
        XCTAssertEqual(try store.allSessions().first?.name, "Tide pools")
    }

    func testAddAssetsToSessionIgnoresDuplicates() throws {
        let session = try store.createSession(name: "S", assetIDs: ["a", "b"])
        try store.addAssets(["b", "c", "d"], toSession: session.id)
        XCTAssertEqual(Set(try store.assetIDs(inSession: session.id)), ["a", "b", "c", "d"])

        // Existing membership (and its burst assignment) survives a re-add.
        try store.assignBurstGroups(["a": "a", "b": "a"], inSession: session.id)
        try store.addAssets(["a"], toSession: session.id)
        XCTAssertEqual(Set(try store.assetIDs(inSession: session.id)), ["a", "b", "c", "d"])
    }

    func testRemoveAssetsFromSession() throws {
        let session = try store.createSession(name: "S", assetIDs: ["a", "b", "c"])
        try store.removeAssets(["a", "c"], fromSession: session.id)
        XCTAssertEqual(try store.assetIDs(inSession: session.id), ["b"])
    }

    func testClearIntentLogAfterApply() throws {
        let session = try store.createSession(name: "S", assetIDs: ["a"])
        let log = try store.makeIntentLog(forSession: session.id)
        log.set(.reject, for: "a")
        try store.clearIntentLog(forSession: session.id)

        let fresh = try store.makeIntentLog(forSession: session.id)
        XCTAssertTrue(fresh.verdicts.isEmpty)
        XCTAssertFalse(fresh.canUndo)
    }

    func testFocusFrameSizeRoundTrip() throws {
        var input = record("a", indexed: true)
        input.focusImageWidth = 9504
        input.focusImageHeight = 6336
        input.focusX = 4870
        input.focusY = 2072
        input.focusFrameWidth = 297
        input.focusFrameHeight = 297
        try store.upsert(input)

        let focus = try XCTUnwrap(try store.asset(id: "a")?.focusLocation)
        XCTAssertEqual(focus.frameWidth, 297)
        XCTAssertNotNil(focus.normalizedFrame)
    }

    // MARK: - Migrations

    func testV1DatabaseUpgradesInPlaceKeepingRows() throws {
        // Simulate a device that ran the app before FocusFrameSize existed:
        // migrate only to v1, write a row, then reopen through IndexStore.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vampire-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path

        let v1Queue = try DatabaseQueue(path: path)
        try IndexStore.migrator.migrate(v1Queue, upTo: "v1")
        try v1Queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_index
                    (assetID, pixelWidth, pixelHeight, isRAW, faceCount, indexedAt)
                VALUES ('old-asset', 9504, 6336, 1, 0, ?)
                """,
                arguments: [Date(timeIntervalSince1970: 1_750_000_000)]
            )
        }
        try v1Queue.close()

        let upgraded = try IndexStore(path: path)
        let fetched = try XCTUnwrap(try upgraded.asset(id: "old-asset"))
        XCTAssertNil(fetched.focusFrameWidth) // new column, backfilled on re-index
        // Pre-signal rows survive but drop out of the resume set: the indexer
        // re-processes them to fill in the HUD signals.
        XCTAssertTrue(try upgraded.indexedAssetIDs().isEmpty)
        XCTAssertEqual(try upgraded.indexedAssetIDs(minimumVersion: 0), ["old-asset"])
    }

    func testFeaturePrintBytesRoundTripExactly() {
        let values: [Float] = [0, -0, .pi, -1e-30, 1e30, .greatestFiniteMagnitude]
        XCTAssertEqual(floats(from: data(from: values)), values)
    }
}
