import Foundation

/// Everything we extract from the head of an ARW. All optional — Sony tag
/// presence varies by model/firmware/drive mode, and a missing tag is data,
/// not an error.
public struct ARWMetadata: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var orientation: Int?
    public var dateTimeOriginal: Date?
    /// ExifImage dimensions (0xA002/0xA003) — the coordinate space camera
    /// pixel values (Fuji FocusPixel/FacePositions) live in.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var makerNote: MakerNoteData?

    public var focusLocation: FocusLocation? { makerNote?.focusLocation }
    /// Face rectangles reported by the camera itself, normalized.
    public var cameraFaces: [NormalizedRect] { makerNote?.faces ?? [] }

    public init() {}
}

/// Parses EXIF + Sony MakerNotes from the *head* of an ARW file.
///
/// Intended use (the only sanctioned one — see CLAUDE.md hard constraint 3):
/// stream chunks from `PHAssetResourceManager.requestData`, append into a
/// buffer, call `parse(head:)` after each chunk; on success or a
/// non-`truncated` error, cancel the request. EXIF + MakerNotes live in
/// roughly the first 1MB, so `recommendedHeadLength` is the give-up point.
public enum ARWHeadParser {
    public static let recommendedHeadLength = 1 << 20 // 1 MiB

    enum ExifTag {
        static let make: UInt16 = 0x010F
        static let model: UInt16 = 0x0110
        static let orientation: UInt16 = 0x0112
        static let exifIFDPointer: UInt16 = 0x8769
        static let dateTimeOriginal: UInt16 = 0x9003
        static let subSecTimeOriginal: UInt16 = 0x9291
        static let makerNote: UInt16 = 0x927C
        static let pixelXDimension: UInt16 = 0xA002
        static let pixelYDimension: UInt16 = 0xA003
    }

    public static func parse(head data: Data) throws -> ARWMetadata {
        let reader = try TIFF.reader(forTIFFData: data)
        let ifd0 = try TIFF.parseIFD(in: reader, at: try TIFF.firstIFDOffset(in: reader))

        var metadata = ARWMetadata()
        if let entry = ifd0.entry(tag: ExifTag.make) {
            metadata.make = try TIFF.asciiValue(of: entry, in: reader)
        }
        if let entry = ifd0.entry(tag: ExifTag.model) {
            metadata.model = try TIFF.asciiValue(of: entry, in: reader)
        }
        if let entry = ifd0.entry(tag: ExifTag.orientation) {
            metadata.orientation = (try TIFF.unsignedValues(of: entry, in: reader)).first.map(Int.init)
        }

        guard let exifPointer = ifd0.entry(tag: ExifTag.exifIFDPointer) else {
            return metadata // no EXIF IFD: unusual but not malformed
        }
        let exifOffset = Int(try TIFF.unsignedValues(of: exifPointer, in: reader)[0])
        let exifIFD = try TIFF.parseIFD(in: reader, at: exifOffset)

        metadata.dateTimeOriginal = try captureDate(in: exifIFD, reader: reader)

        if let entry = exifIFD.entry(tag: ExifTag.pixelXDimension) {
            metadata.pixelWidth = (try TIFF.unsignedValues(of: entry, in: reader)).first.map(Int.init)
        }
        if let entry = exifIFD.entry(tag: ExifTag.pixelYDimension) {
            metadata.pixelHeight = (try TIFF.unsignedValues(of: entry, in: reader)).first.map(Int.init)
        }

        if let makerNoteEntry = exifIFD.entry(tag: ExifTag.makerNote) {
            metadata.makerNote = try parseMakerNote(
                entry: makerNoteEntry,
                in: reader,
                metadata: metadata
            )
        }
        return metadata
    }

    /// Vendor dispatch by maker note signature. Unknown vendors are data, not
    /// errors — the rest of the metadata still counts.
    private static func parseMakerNote(
        entry: TIFF.Entry,
        in reader: ByteReader,
        metadata: ARWMetadata
    ) throws -> MakerNoteData? {
        if (try? reader.bytes(at: entry.valueOffset, count: 8)) == FujiMakerNote.signature {
            return try FujiMakerNote.parse(
                in: reader,
                makerNoteOffset: entry.valueOffset,
                byteCount: entry.count,
                imageWidth: metadata.pixelWidth,
                imageHeight: metadata.pixelHeight
            )
        }
        // Sony: signed header or the A7RV-generation bare IFD. Its value
        // pointers are TIFF-header-relative, hence the whole-buffer reader.
        do {
            return try SonyMakerNote.parse(
                in: reader,
                makerNoteOffset: entry.valueOffset,
                byteCount: entry.count
            )
        } catch ARWParseError.malformed {
            return nil // unrecognized vendor: keep the EXIF we already have
        }
    }

    /// DateTimeOriginal + SubSecTimeOriginal → Date with subsecond precision.
    /// Subseconds matter: burst clustering thresholds are ~1–2s and a 10fps
    /// drive writes frames 100ms apart.
    private static func captureDate(in exifIFD: TIFF.IFD, reader: ByteReader) throws -> Date? {
        guard let entry = exifIFD.entry(tag: ExifTag.dateTimeOriginal) else { return nil }
        let string = try TIFF.asciiValue(of: entry, in: reader)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = formatter.date(from: string) else { return nil }

        if let subSecEntry = exifIFD.entry(tag: ExifTag.subSecTimeOriginal),
           let subSec = try? TIFF.asciiValue(of: subSecEntry, in: reader),
           !subSec.isEmpty,
           let fraction = Double("0.\(subSec)") {
            date.addTimeInterval(fraction)
        }
        return date
    }
}
