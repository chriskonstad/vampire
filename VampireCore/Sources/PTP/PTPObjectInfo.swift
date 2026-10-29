import Foundation

/// Parsers for the PTP datasets returned by GetObjectHandles / GetStorageIDs
/// (both are PTP arrays: u32 count + that many u32 elements) and GetObjectInfo.
public enum PTPDataset {
    /// A PTP array of UInt32 (storage IDs, object handles).
    public static func u32Array(_ data: Data) throws -> [UInt32] {
        var r = PTPReader(data)
        let count = Int(try r.u32())
        guard count >= 0, count <= 1_000_000 else {
            throw PTPWireError.malformed("implausible PTP array count \(count)")
        }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for _ in 0 ..< count { out.append(try r.u32()) }
        return out
    }
}

/// The fields of a GetObjectInfo dataset the culling UI needs. The full
/// ObjectInfo has more; we read the leading fixed fields plus the filename.
public struct PTPObjectInfo: Equatable {
    public let storageID: UInt32
    public let objectFormat: UInt16
    public let compressedSize: UInt32   // file size in bytes (0xFFFFFFFF if >4GB)
    public let thumbFormat: UInt16
    public let thumbCompressedSize: UInt32
    public let imagePixWidth: UInt32
    public let imagePixHeight: UInt32
    public let filename: String

    public var format: PTPObjectFormat { PTPObjectFormat(rawValue: objectFormat) ?? .unknown }
    public var isImage: Bool { objectFormat != PTPObjectFormat.association.rawValue && objectFormat != 0 }

    /// Looks like a Sony RAW either by vendor format code or filename.
    public var isRAW: Bool {
        objectFormat == PTPObjectFormat.sonyRAW.rawValue || filename.lowercased().hasSuffix(".arw")
    }

    /// Parses the standard PTP ObjectInfo dataset layout.
    public init(from data: Data) throws {
        var r = PTPReader(data)
        storageID = try r.u32()
        objectFormat = try r.u16()
        _ = try r.u16()                 // protection status
        compressedSize = try r.u32()
        thumbFormat = try r.u16()
        thumbCompressedSize = try r.u32()
        _ = try r.u32()                 // thumb pix width
        _ = try r.u32()                 // thumb pix height
        imagePixWidth = try r.u32()
        imagePixHeight = try r.u32()
        _ = try r.u32()                 // image bit depth
        _ = try r.u32()                 // parent object
        _ = try r.u16()                 // association type
        _ = try r.u32()                 // association description
        _ = try r.u32()                 // sequence number
        filename = try r.ptpString()
        // Capture date / modification date / keywords follow; unused.
    }

    public init(storageID: UInt32, objectFormat: UInt16, compressedSize: UInt32,
                thumbFormat: UInt16 = 0, thumbCompressedSize: UInt32 = 0,
                imagePixWidth: UInt32 = 0, imagePixHeight: UInt32 = 0, filename: String) {
        self.storageID = storageID; self.objectFormat = objectFormat
        self.compressedSize = compressedSize; self.thumbFormat = thumbFormat
        self.thumbCompressedSize = thumbCompressedSize
        self.imagePixWidth = imagePixWidth; self.imagePixHeight = imagePixHeight
        self.filename = filename
    }
}
