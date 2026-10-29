import Foundation

/// One shot on the card as Sony's remote-transfer list (0x923C) reports it.
/// A RAW+JPEG/HEIF pair is one content with several files.
public struct SonyContent: Equatable, Sendable {
    public let contentID: UInt32
    public let createdUTCms: UInt64
    /// In-camera star rating (0 = none). Lets field favorites carry over.
    public let rating: Int32
    public let isProtected: Bool
    public let files: [SonyContentFile]
}

public struct SonyContentFile: Equatable, Sendable {
    public let fileID: UInt16
    public let path: String          // "A:/DCIM/100MSDCF/DSC00001.ARW"
    public let format: UInt16        // 0x3801 JPEG, 0xB101 ARW, 0xB110 HEIF
    public let size: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32

    public var filename: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var isRAW: Bool { format == PTPObjectFormat.sonyRAW.rawValue }
}

/// Parsers and parameter encoders for Sony's remote-transfer ops.
public enum SonyRemoteTransfer {
    public static let pageSize: UInt32 = 100

    /// 0x923C params: cursor (created-UTC ms of the last item, 0 = start),
    /// page size, slot.
    public static func contentsListParameters(cursor: UInt64, slot: UInt32) -> [UInt32] {
        [UInt32(cursor & 0xFFFF_FFFF), UInt32(cursor >> 32), pageSize, slot, 0]
    }

    /// File selector shared by 0x923D/0x923E: slot in the top byte.
    public static func fileSelector(slot: UInt32, fileID: UInt16) -> UInt32 {
        (slot << 24) | UInt32(fileID)
    }

    /// 0x923D params: read `size` bytes at `offset`; bit 31 of the size marks
    /// the chunk that reaches the end of the file.
    public static func contentsDataParameters(contentID: UInt32, slot: UInt32, fileID: UInt16,
                                              offset: UInt64, size: UInt32, fileSize: UInt64) -> [UInt32] {
        let isLast = offset + UInt64(size) >= fileSize
        return [contentID, fileSelector(slot: slot, fileID: fileID),
                UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32),
                size | (isLast ? 0x8000_0000 : 0)]
    }

    /// 0x923B reply: u32 count + count × u64 capture dates.
    public static func capturedDateCount(_ data: Data) throws -> Int {
        var r = PTPReader(data)
        return Int(try r.u32())
    }

    /// 0x923C reply: 0x90-byte header, u32 count, then contents.
    public static func parseContentsList(_ data: Data) throws -> [SonyContent] {
        var r = PTPReader(data)
        _ = try r.bytes(0x90)
        let count = Int(try r.u32())
        guard count <= 10_000 else { throw PTPWireError.malformed("implausible contents count \(count)") }
        var contents: [SonyContent] = []
        for _ in 0 ..< count {
            _ = try r.u32()                         // type (1 still, 4 movie)
            let contentID = try r.u32()
            for _ in 0 ..< 5 { _ = try r.u32() }    // dir, file no, group type/id, representative
            let created = try r.u64()
            for _ in 0 ..< 3 { _ = try r.u64() }    // modified, created/modified local
            let rating = Int32(bitPattern: try r.u32())
            let protected = try r.u32() != 0
            _ = try r.u32()                         // dummy
            _ = try r.bytes(Int(try r.u32()))       // shot marks
            let fileCount = Int(try r.u32())
            guard fileCount <= 16 else { throw PTPWireError.malformed("implausible file count \(fileCount)") }
            var files: [SonyContentFile] = []
            for _ in 0 ..< fileCount {
                let fileID = try r.u16(); _ = try r.u16()
                let pathBytes = try r.bytes(Int(try r.u32()))
                let path = String(decoding: pathBytes.prefix { $0 != 0 }, as: UTF8.self)
                let format = UInt16(truncatingIfNeeded: try r.u32())
                let size = try r.u64()
                _ = try r.bytes(32)                 // UMID
                var w: UInt32 = 0, h: UInt32 = 0
                if try r.u32() != 0 { w = try r.u32(); h = try r.u32() }
                if try r.u32() != 0 { _ = try r.bytes(19 * 4) }  // video params
                if try r.u32() != 0 { _ = try r.bytes(4 * 4) }   // audio params
                files.append(SonyContentFile(fileID: fileID, path: path, format: format,
                                             size: size, pixelWidth: w, pixelHeight: h))
            }
            contents.append(SonyContent(contentID: contentID, createdUTCms: created,
                                        rating: rating, isProtected: protected, files: files))
        }
        return contents
    }
}
