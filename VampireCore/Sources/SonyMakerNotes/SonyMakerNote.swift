import Foundation

/// The active AF point as written by Sony bodies (A7RV generation) into
/// MakerNotes tag 0x2027 `FocusLocation`: image width/height plus focus X/Y,
/// in pixels of the full-frame output image.
///
/// APS-C crop mode changes the coordinate framing — the width/height carried
/// inside the tag are authoritative for normalization, which is why we expose
/// the normalized point rather than letting callers divide by asset pixel size.
public struct FocusLocation: Equatable, Codable, Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let x: Int
    public let y: Int
    /// AF frame size from tag 0x2037 `FocusFrameSize`, same pixel space as
    /// the focus point. Nil when the body didn't write the tag.
    public var frameWidth: Int?
    public var frameHeight: Int?

    public init(imageWidth: Int, imageHeight: Int, x: Int, y: Int,
                frameWidth: Int? = nil, frameHeight: Int? = nil) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.x = x
        self.y = y
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    /// Focus point in unit coordinates (0...1, origin top-left), or nil if the
    /// tag carried zero dimensions (seen on some manual-focus frames).
    public var normalizedPoint: (x: Double, y: Double)? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        return (Double(x) / Double(imageWidth), Double(y) / Double(imageHeight))
    }

    /// The AF frame as a unit rect centered on the focus point, when the body
    /// wrote a frame size (A7RV does: 0x2037).
    public var normalizedFrame: (x: Double, y: Double, width: Double, height: Double)? {
        guard let point = normalizedPoint,
              let frameWidth, let frameHeight, frameWidth > 0, frameHeight > 0 else { return nil }
        let w = Double(frameWidth) / Double(imageWidth)
        let h = Double(frameHeight) / Double(imageHeight)
        return (point.x - w / 2, point.y - h / 2, w, h)
    }
}

/// A face rectangle in unit coordinates (0...1, top-left origin), as reported
/// by the camera itself (e.g. Fuji FacePositions).
public struct NormalizedRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Parsed maker notes (Sony or Fujifilm). Extend by adding tag cases and
/// fields here — but per CLAUDE.md, only after validating layout against a
/// real fixture.
public struct MakerNoteData: Equatable, Sendable {
    public var focusLocation: FocusLocation?
    /// Camera-reported face rectangles, normalized to the output image.
    public var faces: [NormalizedRect] = []
    /// Raw integer values of recognized-but-unmodeled tags, for fixture-driven
    /// exploration (`exiftool -v3` comparison) without re-parsing.
    public var rawTagValues: [UInt16: [UInt32]] = [:]

    public init() {}
}

public typealias SonyMakerNoteData = MakerNoteData

enum SonyTag: UInt16 {
    case focusLocation = 0x2027
    case focusFrameSize = 0x2037
}

enum SonyMakerNote {
    /// Sony maker note signatures (from exiftool's MakerNotes.pm). The IFD
    /// starts 12 bytes in; value pointers are relative to the TIFF header,
    /// which is why parsing happens in the whole-file reader, not a slice.
    private static let signatures: [Data] = [
        Data("SONY DSC \0\0\0".utf8),
        Data("SONY CAM \0\0\0".utf8),
        Data("SONY MOBILE\0".utf8),
        Data("\0\0SONY PIC\0\0".utf8),
    ]
    static let headerLength = 12

    static func parse(in reader: ByteReader, makerNoteOffset: Int, byteCount: Int) throws -> SonyMakerNoteData {
        let ifdOffset: Int
        let header = try reader.bytes(at: makerNoteOffset, count: headerLength)
        if signatures.contains(where: { header == $0 || header.starts(with: $0.prefix(9)) }) {
            ifdOffset = makerNoteOffset + headerLength
        } else if looksLikeBareIFD(in: reader, at: makerNoteOffset) {
            // A7RV-generation bodies write no signature at all: the maker note
            // is a bare IFD from byte 0, value pointers still TIFF-base-
            // relative. Validated against fixtures/DSC04319.ARW (ILCE-7RM5),
            // cross-checked with exiftool -v3.
            ifdOffset = makerNoteOffset
        } else {
            throw ARWParseError.malformed("unrecognized maker note layout")
        }

        let ifd = try TIFF.parseIFD(in: reader, at: ifdOffset)
        var result = SonyMakerNoteData()
        var frameSize: (width: Int, height: Int)?

        for entry in ifd.entries {
            switch SonyTag(rawValue: entry.tag) {
            case .focusLocation:
                let values = try TIFF.unsignedValues(of: entry, in: reader)
                guard values.count >= 4 else {
                    throw ARWParseError.malformed("FocusLocation has \(values.count) values, expected 4")
                }
                result.focusLocation = FocusLocation(
                    imageWidth: Int(values[0]),
                    imageHeight: Int(values[1]),
                    x: Int(values[2]),
                    y: Int(values[3])
                )
                result.rawTagValues[entry.tag] = values
            case .focusFrameSize:
                // undef[6] read as int16u[3]: frame width, height, unknown
                // (fixture DSC04319: 297 297 257; exiftool agrees).
                let values = try TIFF.uint16Values(of: entry, in: reader)
                if values.count >= 2, values[0] > 0, values[1] > 0 {
                    frameSize = (Int(values[0]), Int(values[1]))
                }
                result.rawTagValues[entry.tag] = values.map(UInt32.init)
            case nil:
                // Stash small integer tags for fixture-driven exploration; skip
                // big blobs (0x94xx ciphered sections etc.) — those need
                // per-model handling we won't build without fixtures.
                if entry.count <= 16,
                   let values = try? TIFF.unsignedValues(of: entry, in: reader) {
                    result.rawTagValues[entry.tag] = values
                }
            }
        }

        // Tag order in the IFD is not guaranteed; attach the frame after the walk.
        if let frameSize {
            result.focusLocation?.frameWidth = frameSize.width
            result.focusLocation?.frameHeight = frameSize.height
        }
        return result
    }

    /// Structural sniff for signatureless maker notes: a sane entry count
    /// whose first few entries carry valid TIFF field types. Random non-IFD
    /// bytes (other vendors' signatures, ciphered blobs) fail this.
    private static func looksLikeBareIFD(in reader: ByteReader, at offset: Int) -> Bool {
        guard let count = try? reader.uint16(at: offset), count > 0, count <= 0x400 else {
            return false
        }
        let probe = min(Int(count), 4)
        for i in 0 ..< probe {
            let entryOffset = offset + 2 + i * 12
            guard let rawType = try? reader.uint16(at: entryOffset + 2),
                  TIFF.FieldType(rawValue: rawType) != nil,
                  let entryCount = try? reader.uint32(at: entryOffset + 4),
                  entryCount < 1 << 24 else {
                return false
            }
        }
        return true
    }
}
