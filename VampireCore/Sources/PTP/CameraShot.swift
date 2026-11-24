import Foundation

/// One shot on the camera card, as seen over Sony remote transfer. Points at
/// the RAW file of a RAW+JPEG/HEIF pair when there is one. Pure data — the
/// wire codec that produces it lives next to this in `PTP`, and the on-disk
/// cache that serializes it keys off `indexID`.
public struct CameraPhoto: Identifiable, Hashable, Sendable {
    public let slot: UInt32
    public let contentID: UInt32
    public let fileID: UInt16
    public let filename: String
    public let sizeBytes: UInt64
    public let isRAW: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let createdUTCms: UInt64
    /// In-camera star rating / protect — favorites marked while shooting.
    public let rating: Int
    public let isProtected: Bool

    public init(
        slot: UInt32, contentID: UInt32, fileID: UInt16, filename: String,
        sizeBytes: UInt64, isRAW: Bool, pixelWidth: Int, pixelHeight: Int,
        createdUTCms: UInt64, rating: Int, isProtected: Bool
    ) {
        self.slot = slot
        self.contentID = contentID
        self.fileID = fileID
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.isRAW = isRAW
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdUTCms = createdUTCms
        self.rating = rating
        self.isProtected = isProtected
    }

    public struct ID: Hashable, Sendable {
        public let slot: UInt32
        public let contentID: UInt32
    }
    public var id: ID { ID(slot: slot, contentID: contentID) }
    public var capturedAt: Date { Date(timeIntervalSince1970: Double(createdUTCms) / 1000) }

    /// Index/journal key for a shot on the card: filename + millisecond
    /// capture time. Survives reconnects and moving the card between slots
    /// (Sony content IDs and slots don't), and filenames reused after a
    /// format/rollover still differ by capture time.
    public var indexID: String { "camera:\(filename)@\(createdUTCms)" }
}

/// File-name encoding for the on-disk cull-frame cache. Pure string logic,
/// kept out of the app layer so it can be unit-tested — a bug here silently
/// mislabels which shots are cached on disk (hard constraint: cache files
/// must be keyed by the same identity the rest of the app uses).
public enum CameraFrameIdentity {
    /// "camera:DSC05508.ARW@1793247396115" -> "DSC05508.ARW-1793247396115"
    /// (`camera:` dropped, `@` -> `-`, `/` -> `_`).
    public static func fileStem(forIndexID id: String) -> String {
        String(id.dropFirst("camera:".count))
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Inverse of `fileStem` for cached-file names: strips the known
    /// suffixes and recovers `(indexID, isThumbnail)`. Grid/preview/thumb
    /// suffixes are disjoint; `.grid.jpg` is not a thumbnail.
    public static func indexID(forFileName name: String) -> (id: String, isThumbnail: Bool)? {
        let isThumb = name.hasSuffix(".thumb.jpg")
        guard isThumb || (name.hasSuffix(".jpg") && !name.hasSuffix(".grid.jpg")) else { return nil }
        let stem = name.dropLast(isThumb ? ".thumb.jpg".count : ".jpg".count)
        // The timestamp is digits, so the last "-" splits filename from it.
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let filename = String(stem[..<dash])
        let ms = String(stem[stem.index(after: dash)...])
        guard !filename.isEmpty, !ms.isEmpty, ms.allSatisfy(\.isNumber) else { return nil }
        return ("camera:\(filename)@\(ms)", isThumb)
    }
}

/// The card listing is the truth: it is adopted wholesale (new shots in,
/// removed shots out). Kept pure so the diff logic is unit-testable without
/// the camera or the file system.
public struct CardListingResult: Sendable, Equatable {
    /// The listing, sorted by capture time (ascending).
    public let photos: [CameraPhoto]
    /// Shots that were on the card but are not in `known` — i.e. arrived.
    public let fresh: [CameraPhoto]
    /// Index IDs previously seen that are no longer on the card.
    public let gone: Set<String>
}

public enum CardListing {
    public static func merge(known: [CameraPhoto], list: [CameraPhoto]) -> CardListingResult {
        let knownIDs = Set(known.map(\.indexID))
        let onCardIDs = Set(list.map(\.indexID))
        let fresh = list.filter { !knownIDs.contains($0.indexID) }
        let gone = knownIDs.subtracting(onCardIDs)
        let photos = list.sorted { $0.createdUTCms < $1.createdUTCms }
        return CardListingResult(photos: photos, fresh: fresh, gone: gone)
    }
}
