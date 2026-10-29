import Foundation
import GRDB
import SonyMakerNotes
import CullIntent

/// One indexed asset. Joined to Photos by `PHAsset.localIdentifier` — the one
/// and only identity scheme (hard constraint 5).
///
/// Value type on purpose: the store is the source of truth, records are
/// snapshots the UI reads.
public struct AssetIndexRecord: Codable, Equatable, Sendable {
    public var assetID: String
    public var creationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isRAW: Bool

    // Filled in by the indexing pass; nil until indexed.
    public var indexedAt: Date?
    public var cameraModel: String?
    /// FocusLocation (Sony MakerNotes 0x2027) + FocusFrameSize (0x2037),
    /// flattened for SQLite.
    public var focusImageWidth: Int?
    public var focusImageHeight: Int?
    public var focusX: Int?
    public var focusY: Int?
    public var focusFrameWidth: Int?
    public var focusFrameHeight: Int?
    /// Vision feature print, stored as raw little-endian Float32 bytes.
    public var featurePrintData: Data?
    /// Best face capture quality in the frame (denormalized for fast sorting).
    public var bestFaceQuality: Double?
    public var faceCount: Int
    /// Burst group ID (= asset ID of the group's first frame), nil if ungrouped.
    public var burstGroupID: String?

    // HUD signals (v4). Nil = not computed or not applicable.
    /// Schema version of the extraction that produced this row; rows below
    /// IndexStore.currentIndexVersion are re-indexed.
    public var indexVersion: Int = 0
    public var aestheticScore: Double?      // Vision overall, -1...1
    public var isUtility: Bool?             // screenshots/receipts/docs
    public var horizonDegrees: Double?      // signed tilt
    public var clippedHighlights: Double?   // fraction of blown pixels
    public var crushedShadows: Double?      // fraction of crushed pixels
    public var meanLuma: Double?            // 0...1
    public var salientX: Double?
    public var salientY: Double?
    public var salientWidth: Double?
    public var salientHeight: Double?
    /// Faces caught mid-blink (eyesOpen below threshold); nil = unknown.
    public var closedEyesCount: Int?

    public init(
        assetID: String,
        creationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        isRAW: Bool,
        indexedAt: Date? = nil,
        cameraModel: String? = nil,
        focusLocation: FocusLocation? = nil,
        featurePrintData: Data? = nil,
        bestFaceQuality: Double? = nil,
        faceCount: Int = 0,
        burstGroupID: String? = nil
    ) {
        self.assetID = assetID
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isRAW = isRAW
        self.indexedAt = indexedAt
        self.cameraModel = cameraModel
        self.focusImageWidth = focusLocation?.imageWidth
        self.focusImageHeight = focusLocation?.imageHeight
        self.focusX = focusLocation?.x
        self.focusY = focusLocation?.y
        self.focusFrameWidth = focusLocation?.frameWidth
        self.focusFrameHeight = focusLocation?.frameHeight
        self.featurePrintData = featurePrintData
        self.bestFaceQuality = bestFaceQuality
        self.faceCount = faceCount
        self.burstGroupID = burstGroupID
    }

    public var focusLocation: FocusLocation? {
        guard let w = focusImageWidth, let h = focusImageHeight,
              let x = focusX, let y = focusY else { return nil }
        return FocusLocation(
            imageWidth: w, imageHeight: h, x: x, y: y,
            frameWidth: focusFrameWidth, frameHeight: focusFrameHeight
        )
    }

    public var featurePrint: [Float]? {
        get { featurePrintData.map(floats(from:)) }
        set { featurePrintData = newValue.map(data(from:)) }
    }

    /// Attention-saliency box (top-left normalized), when one was detected.
    public var salientRect: NormalizedRect? {
        get {
            guard let x = salientX, let y = salientY,
                  let w = salientWidth, let h = salientHeight else { return nil }
            return NormalizedRect(x: x, y: y, width: w, height: h)
        }
        set {
            salientX = newValue?.x
            salientY = newValue?.y
            salientWidth = newValue?.width
            salientHeight = newValue?.height
        }
    }

    /// Aesthetic score mapped to a skimmable 0...100.
    public var aestheticScore100: Int? {
        aestheticScore.map { Int((($0 + 1) / 2 * 100).rounded()) }
    }
}

/// A face found by Vision during indexing. Rect is normalized (0...1,
/// top-left origin, matching the preview the UI draws on).
public struct FaceRecord: Codable, Equatable, Sendable {
    public var id: Int64?
    public var assetID: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// VNDetectFaceCaptureQualityRequest score (sharpness/eyes/expression).
    public var captureQuality: Double?
    /// Eye-openness 0...1 from face landmarks (eye aspect ratio); nil unknown.
    /// Below ~0.18 reads as a blink.
    public var eyesOpen: Double?

    public init(id: Int64? = nil, assetID: String, x: Double, y: Double,
                width: Double, height: Double, captureQuality: Double?,
                eyesOpen: Double? = nil) {
        self.id = id
        self.assetID = assetID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.captureQuality = captureQuality
        self.eyesOpen = eyesOpen
    }
}

func floats(from data: Data) -> [Float] {
    data.withUnsafeBytes { raw in
        let bound = raw.bindMemory(to: UInt32.self)
        return bound.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}

func data(from floats: [Float]) -> Data {
    var data = Data(capacity: floats.count * 4)
    for value in floats {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    return data
}

// MARK: - GRDB conformances

extension AssetIndexRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "asset_index"
}

extension FaceRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "face"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persisted row of the append-only intent log.
struct IntentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "intent_log"

    var seq: Int64?
    /// Journal rows are scoped to a culling session. Rows written before
    /// sessions existed carry NULL and are never loaded.
    var sessionID: String?
    var operation: String
    var assetID: String
    var verdict: String?
    var timestamp: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }

    init(record: IntentRecord, sessionID: String) {
        self.seq = nil
        self.sessionID = sessionID
        self.operation = record.operation.rawValue
        self.assetID = record.assetID
        self.verdict = record.verdict?.rawValue
        self.timestamp = record.timestamp
    }

    var intentRecord: IntentRecord? {
        guard let op = IntentRecord.Operation(rawValue: operation) else { return nil }
        return IntentRecord(
            operation: op,
            assetID: assetID,
            verdict: verdict.flatMap(Verdict.init(rawValue:)),
            timestamp: timestamp
        )
    }
}
