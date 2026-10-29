import Foundation
import GRDB

/// A culling session: a user-selected subset of the library, culled over one
/// or more sittings. All mutable culling state (intent journal, burst groups)
/// hangs off the session; the per-asset index is shared across sessions so an
/// asset is never indexed twice.
public struct CullSessionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var lastOpenedAt: Date?
    /// Where the session's photos live: the Photos library (Apply deletes
    /// rejects) or a camera card over Wi-Fi (Apply imports keepers; nothing
    /// is ever deleted).
    public var kind: Kind = .library

    public enum Kind: String, Codable, Sendable {
        case library
        case camera
    }

    public init(id: String = UUID().uuidString, name: String, createdAt: Date,
                lastOpenedAt: Date? = nil, kind: Kind = .library) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.kind = kind
    }
}

extension CullSessionRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cull_session"
}

/// Session membership row. `burstGroupID` lives here, not on the asset index,
/// because clustering is computed over a session's contents and two sessions
/// may slice the same assets differently.
struct SessionAssetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_asset"

    var sessionID: String
    var assetID: String
    var burstGroupID: String?
}

/// Lightweight summary for the session list screen.
public struct SessionSummary: Equatable, Sendable, Identifiable {
    public var record: CullSessionRecord
    public var assetCount: Int
    public var keepCount: Int
    public var rejectCount: Int
    public var maybeCount: Int

    public var id: String { record.id }
    public var decidedCount: Int { keepCount + rejectCount + maybeCount }
}
