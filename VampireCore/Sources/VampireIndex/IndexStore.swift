import Foundation
import GRDB
import CullIntent

/// SQLite-backed index + intent log. Everything expensive the indexer extracts
/// lands here once; the culling UI reads only from here (hard constraint 4).
///
/// GRDB's DatabaseQueue serializes access, so this type is safe to share.
public final class IndexStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public convenience init(path: String) throws {
        try self.init(dbQueue: DatabaseQueue(path: path))
    }

    /// In-memory store for tests and previews.
    public convenience init() throws {
        try self.init(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// Migrations are explicit and versioned; never edit a shipped migration.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "asset_index") { t in
                t.primaryKey("assetID", .text)
                t.column("creationDate", .datetime).indexed()
                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("isRAW", .boolean).notNull()
                t.column("indexedAt", .datetime)
                t.column("cameraModel", .text)
                t.column("focusImageWidth", .integer)
                t.column("focusImageHeight", .integer)
                t.column("focusX", .integer)
                t.column("focusY", .integer)
                t.column("featurePrintData", .blob)
                t.column("bestFaceQuality", .double).indexed()
                t.column("faceCount", .integer).notNull().defaults(to: 0)
                t.column("burstGroupID", .text).indexed()
            }

            try db.create(table: "face") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetID", .text).notNull().indexed()
                    .references("asset_index", onDelete: .cascade)
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("captureQuality", .double)
            }

            try db.create(table: "intent_log") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("operation", .text).notNull()
                t.column("assetID", .text).notNull()
                t.column("verdict", .text)
                t.column("timestamp", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2-focus-frame-size") { db in
            // FocusFrameSize (Sony 0x2037): the AF box dimensions. Existing
            // rows keep nil and get backfilled only if the asset re-indexes.
            try db.alter(table: "asset_index") { t in
                t.add(column: "focusFrameWidth", .integer)
                t.add(column: "focusFrameHeight", .integer)
            }
        }

        migrator.registerMigration("v3-sessions") { db in
            try db.create(table: "cull_session") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
            }
            try db.create(table: "session_asset") { t in
                t.column("sessionID", .text).notNull()
                    .references("cull_session", onDelete: .cascade)
                t.column("assetID", .text).notNull()
                t.column("burstGroupID", .text)
                t.primaryKey(["sessionID", "assetID"])
            }
            // Journal becomes session-scoped. Pre-session rows keep NULL and
            // are simply never loaded again.
            try db.alter(table: "intent_log") { t in
                t.add(column: "sessionID", .text).indexed()
            }
        }

        migrator.registerMigration("v4-hud-signals") { db in
            // Per-photo signals for the culling HUD. All nullable: a signal's
            // absence is data ("not computed / not applicable"), never an
            // error. indexVersion lets the indexer re-process assets indexed
            // before a signal existed.
            try db.alter(table: "asset_index") { t in
                t.add(column: "indexVersion", .integer).notNull().defaults(to: 0)
                t.add(column: "aestheticScore", .double)   // -1...1 (Vision)
                t.add(column: "isUtility", .boolean)       // screenshots, docs
                t.add(column: "horizonDegrees", .double)   // signed tilt
                t.add(column: "clippedHighlights", .double) // fraction 0...1
                t.add(column: "crushedShadows", .double)    // fraction 0...1
                t.add(column: "meanLuma", .double)          // 0...1
                t.add(column: "salientX", .double)          // attention box,
                t.add(column: "salientY", .double)          // normalized
                t.add(column: "salientWidth", .double)
                t.add(column: "salientHeight", .double)
                t.add(column: "closedEyesCount", .integer) // faces mid-blink
            }
            try db.alter(table: "face") { t in
                t.add(column: "eyesOpen", .double) // 0...1 openness, nil unknown
            }
        }

        migrator.registerMigration("v5-session-kind") { db in
            // Camera (wireless field-cull) sessions share the session/journal
            // machinery; existing sessions are library sessions.
            try db.alter(table: "cull_session") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "library")
            }
        }

        return migrator
    }

    // MARK: - Asset index

    public func upsert(_ record: AssetIndexRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func upsert(_ records: [AssetIndexRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    public func asset(id: String) throws -> AssetIndexRecord? {
        try dbQueue.read { db in
            try AssetIndexRecord.fetchOne(db, key: id)
        }
    }

    public func allAssets() throws -> [AssetIndexRecord] {
        try dbQueue.read { db in
            try AssetIndexRecord
                .order(Column("creationDate").asc)
                .fetchAll(db)
        }
    }

    /// Bump when the extraction pipeline learns a new signal: rows recorded
    /// with an older version re-index automatically.
    /// v3: preview orientation passed to Vision (portrait faces were missed).
    /// v4: AF point/frame stored in upright display space (portrait AF boxes
    ///     were drawn in sensor space, i.e. in the wrong place).
    public static let currentIndexVersion = 4

    /// IDs already indexed at the current pipeline version — the indexer
    /// skips these, making the pass resumable.
    public func indexedAssetIDs(minimumVersion: Int = IndexStore.currentIndexVersion) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT assetID FROM asset_index WHERE indexedAt IS NOT NULL AND indexVersion >= ?",
                arguments: [minimumVersion]
            ))
        }
    }

    public func deleteAssets(ids: [String]) throws {
        try dbQueue.write { db in
            _ = try AssetIndexRecord.deleteAll(db, keys: ids)
        }
    }

    // MARK: - Faces

    /// Replaces the faces of an asset (re-index overwrites, never duplicates).
    public func replaceFaces(_ faces: [FaceRecord], forAsset assetID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM face WHERE assetID = ?", arguments: [assetID])
            for var face in faces {
                precondition(face.assetID == assetID)
                try face.insert(db)
            }
        }
    }

    public func faces(forAsset assetID: String) throws -> [FaceRecord] {
        try dbQueue.read { db in
            try FaceRecord
                .filter(Column("assetID") == assetID)
                .order(Column("captureQuality").desc)
                .fetchAll(db)
        }
    }

    /// All faces, best quality first — powers the quality-ranked face strip.
    public func facesByQuality(limit: Int) throws -> [FaceRecord] {
        try dbQueue.read { db in
            try FaceRecord
                .filter(Column("captureQuality") != nil)
                .order(Column("captureQuality").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Sessions

    public func createSession(name: String, assetIDs: [String], createdAt: Date = Date(),
                              kind: CullSessionRecord.Kind = .library) throws -> CullSessionRecord {
        let session = CullSessionRecord(name: name, createdAt: createdAt, lastOpenedAt: createdAt, kind: kind)
        try dbQueue.write { db in
            try session.insert(db)
            for assetID in assetIDs {
                try SessionAssetRow(sessionID: session.id, assetID: assetID, burstGroupID: nil)
                    .insert(db, onConflict: .ignore)
            }
        }
        return session
    }

    /// Most recently opened first — the resume order.
    public func allSessions() throws -> [CullSessionRecord] {
        try dbQueue.read { db in
            try CullSessionRecord
                .order(Column("lastOpenedAt").desc, Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Session list with per-session verdict counts, derived by replaying
    /// each session's (small) journal.
    public func sessionSummaries() throws -> [SessionSummary] {
        try allSessions().map { record in
            let counts = IntentLog(replaying: try loadIntentRecords(forSession: record.id)).counts
            return SessionSummary(
                record: record,
                assetCount: try assetIDs(inSession: record.id).count,
                keepCount: counts[.keep, default: 0],
                rejectCount: counts[.reject, default: 0],
                maybeCount: counts[.maybe, default: 0]
            )
        }
    }

    /// Deletes the session, its membership and journal. Asset index rows are
    /// untouched — they're shared across sessions.
    public func deleteSession(id: String) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM intent_log WHERE sessionID = ?", arguments: [id])
            try CullSessionRecord.deleteOne(db, key: id)
        }
    }

    public func renameSession(id: String, name: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE cull_session SET name = ? WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    /// Adds assets to an existing session; already-member assets are ignored.
    public func addAssets(_ assetIDs: [String], toSession sessionID: String) throws {
        try dbQueue.write { db in
            for assetID in assetIDs {
                try SessionAssetRow(sessionID: sessionID, assetID: assetID, burstGroupID: nil)
                    .insert(db, onConflict: .ignore)
            }
        }
    }

    public func markSessionOpened(id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE cull_session SET lastOpenedAt = ? WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    public func assetIDs(inSession sessionID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT assetID FROM session_asset WHERE sessionID = ?",
                arguments: [sessionID]
            )
        }
    }

    /// Drops assets from a session (e.g. rejects that were applied and no
    /// longer exist in the library).
    public func removeAssets(_ assetIDs: [String], fromSession sessionID: String) throws {
        try dbQueue.write { db in
            for assetID in assetIDs {
                try db.execute(
                    sql: "DELETE FROM session_asset WHERE sessionID = ? AND assetID = ?",
                    arguments: [sessionID, assetID]
                )
            }
        }
    }

    // MARK: - Burst groups (per session)

    /// Persists a clustering result for one session: assetID → burstGroupID
    /// (nil clears). Different sessions may cluster the same assets differently.
    public func assignBurstGroups(_ assignments: [String: String?], inSession sessionID: String) throws {
        try dbQueue.write { db in
            for (assetID, groupID) in assignments {
                try db.execute(
                    sql: "UPDATE session_asset SET burstGroupID = ? WHERE sessionID = ? AND assetID = ?",
                    arguments: [groupID, sessionID, assetID]
                )
            }
        }
    }

    // MARK: - Intent log (per session)

    public func appendIntent(_ record: IntentRecord, sessionID: String) throws {
        try dbQueue.write { db in
            var row = IntentRow(record: record, sessionID: sessionID)
            try row.insert(db)
        }
    }

    public func loadIntentRecords(forSession sessionID: String) throws -> [IntentRecord] {
        try dbQueue.read { db in
            try IntentRow
                .filter(Column("sessionID") == sessionID)
                .order(Column("seq").asc)
                .fetchAll(db)
                .compactMap(\.intentRecord)
        }
    }

    /// Wipes a session's journal after a successful Apply: applied decisions
    /// are now reflected in the Photos library itself.
    public func clearIntentLog(forSession sessionID: String) throws {
        _ = try dbQueue.write { db in
            try IntentRow.filter(Column("sessionID") == sessionID).deleteAll(db)
        }
    }

    /// Forgets the journal entries for these assets in one session — used
    /// when shots leave the camera card, so their decisions don't linger
    /// in counts or undo history. Other assets' history is untouched.
    public func removeIntents(forAssets assetIDs: [String], inSession sessionID: String) throws {
        guard !assetIDs.isEmpty else { return }
        _ = try dbQueue.write { db in
            try IntentRow
                .filter(Column("sessionID") == sessionID)
                .filter(assetIDs.contains(Column("assetID")))
                .deleteAll(db)
        }
    }

    /// Restores a session's live IntentLog, wired to persist every future
    /// mutation back into that session's journal.
    public func makeIntentLog(forSession sessionID: String) throws -> IntentLog {
        let log = IntentLog(replaying: try loadIntentRecords(forSession: sessionID))
        log.onAppend = { [weak self] record in
            // Append failures must not lose the user's tap: state stays
            // in-memory; worst case the journal misses an entry on disk.
            try? self?.appendIntent(record, sessionID: sessionID)
        }
        return log
    }
}
