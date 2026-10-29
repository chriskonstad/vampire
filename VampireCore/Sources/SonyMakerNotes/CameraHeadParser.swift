import Foundation

/// Container-format dispatch for head-of-file metadata parsing. Three shapes:
/// - TIFF (Sony ARW): II/MM magic → straight to the IFD walk.
/// - Fuji RAF: "FUJIFILMCCD-RAW " container wrapping an EXIF-bearing JPEG
///   (offset at byte 84, big-endian).
/// - JPEG (Fuji JPEG shooters, or any EXIF JPEG): APP1 "Exif" segment wraps
///   a TIFF buffer.
///
/// `ARWParseError.truncated` propagates from every path so HeadParseSession's
/// fetch-more-and-retry loop works for all three.
public enum CameraHeadParser {
    public static func parse(head data: Data) throws -> ARWMetadata {
        guard data.count >= 16 else { throw ARWParseError.truncated(needed: 16) }

        if data.starts(with: RAFContainer.magic) {
            return try RAFContainer.parse(head: data)
        }
        if data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            let tiff = try JPEGSegments.exifTIFFData(in: data, jpegStart: 0)
            return try ARWHeadParser.parse(head: tiff)
        }
        // TIFF (or unrecognized — ARWHeadParser reports .notTIFF).
        return try ARWHeadParser.parse(head: data)
    }
}

enum RAFContainer {
    static let magic = Data("FUJIFILMCCD-RAW ".utf8)
    /// Byte positions of the embedded-JPEG offset/length fields (big-endian),
    /// verified against fixtures/DSCF2030.raf.
    private static let jpegOffsetField = 84

    static func parse(head data: Data) throws -> ARWMetadata {
        let reader = ByteReader(data: data, endianness: .big)
        let jpegOffset = Int(try reader.uint32(at: jpegOffsetField))
        guard jpegOffset > 0, jpegOffset < 1 << 24 else {
            throw ARWParseError.malformed("implausible RAF JPEG offset \(jpegOffset)")
        }
        let tiff = try JPEGSegments.exifTIFFData(in: data, jpegStart: jpegOffset)
        return try ARWHeadParser.parse(head: tiff)
    }
}

enum JPEGSegments {
    /// Walks JPEG markers from `jpegStart` and returns the TIFF buffer inside
    /// the APP1 "Exif" segment.
    static func exifTIFFData(in data: Data, jpegStart: Int) throws -> Data {
        let reader = ByteReader(data: data, endianness: .big) // JPEG lengths are BE
        guard try reader.uint16(at: jpegStart) == 0xFFD8 else {
            throw ARWParseError.malformed("no JPEG SOI at offset \(jpegStart)")
        }

        var cursor = jpegStart + 2
        for _ in 0 ..< 64 { // EXIF APP1 sits in the first few segments
            let marker = try reader.uint16(at: cursor)
            guard (0xFFE0 ... 0xFFFE).contains(marker) else {
                throw ARWParseError.malformed("unexpected JPEG marker 0x\(String(marker, radix: 16))")
            }
            // Entropy-coded data starts at SOS; EXIF must come before it.
            if marker == 0xFFDA { break }
            let length = Int(try reader.uint16(at: cursor + 2)) // includes the 2 length bytes
            let payloadStart = cursor + 4
            if marker == 0xFFE1,
               (try? reader.bytes(at: payloadStart, count: 6)) == Data("Exif\0\0".utf8) {
                let tiffStart = payloadStart + 6
                let tiffLength = length - 2 - 6
                return try reader.bytes(at: tiffStart, count: tiffLength)
            }
            cursor += 2 + length
        }
        throw ARWParseError.malformed("no EXIF APP1 segment found")
    }
}
