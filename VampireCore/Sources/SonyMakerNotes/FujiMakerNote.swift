import Foundation

/// Fujifilm maker note parser, validated against fixtures/DSCF2030.raf and
/// fixtures/DSCF2763.jpg (X-T5), cross-checked with exiftool -v3.
///
/// Layout: "FUJIFILM" (8 bytes) + LE uint32 IFD offset; the IFD and all of
/// its value pointers are relative to the START OF THE MAKER NOTE — not the
/// TIFF header like Sony. Always little-endian.
enum FujiMakerNote {
    static let signature = Data("FUJIFILM".utf8)

    enum FujiTag: UInt16 {
        /// Focus point in ExifImage pixel coordinates (int16u[2], inline).
        case focusPixel = 0x1023
        case facesDetected = 0x4100
        /// Per face: x1 y1 x2 y2 corner coords in ExifImage pixel space.
        case facePositions = 0x4103
    }

    /// `imageWidth/Height` are the ExifImage dimensions from the Exif IFD —
    /// the coordinate space Fuji's pixel values live in.
    static func parse(
        in reader: ByteReader,
        makerNoteOffset: Int,
        byteCount: Int,
        imageWidth: Int?,
        imageHeight: Int?
    ) throws -> MakerNoteData {
        guard try reader.bytes(at: makerNoteOffset, count: 8) == signature else {
            throw ARWParseError.malformed("not a Fujifilm maker note")
        }
        // Sub-reader rebased to the maker note start: Fuji offsets are
        // maker-note-relative.
        let slice = try reader.bytes(at: makerNoteOffset, count: max(byteCount, 16))
        let sub = ByteReader(data: slice, endianness: .little)
        let ifdOffset = Int(try sub.uint32(at: 8))
        let ifd = try TIFF.parseIFD(in: sub, at: ifdOffset)

        var result = MakerNoteData()
        var focusPixel: (x: Int, y: Int)?
        var faceCorners: [UInt16] = []

        for entry in ifd.entries {
            switch FujiTag(rawValue: entry.tag) {
            case .focusPixel:
                let values = try TIFF.uint16Values(of: entry, in: sub)
                if values.count >= 2 {
                    focusPixel = (Int(values[0]), Int(values[1]))
                    result.rawTagValues[entry.tag] = values.map(UInt32.init)
                }
            case .facesDetected:
                let values = try TIFF.unsignedValues(of: entry, in: sub)
                result.rawTagValues[entry.tag] = values
            case .facePositions:
                faceCorners = try TIFF.uint16Values(of: entry, in: sub)
                result.rawTagValues[entry.tag] = faceCorners.map(UInt32.init)
            case nil:
                if entry.count <= 16,
                   let values = try? TIFF.unsignedValues(of: entry, in: sub) {
                    result.rawTagValues[entry.tag] = values
                }
            }
        }

        guard let width = imageWidth, let height = imageHeight, width > 0, height > 0 else {
            // Without the pixel space, coordinates can't be normalized.
            return result
        }

        if let focusPixel {
            result.focusLocation = FocusLocation(
                imageWidth: width,
                imageHeight: height,
                x: focusPixel.x,
                y: focusPixel.y
            )
        }
        // Corner pairs → normalized rects.
        for base in stride(from: 0, to: faceCorners.count - 3, by: 4) {
            let x1 = Double(faceCorners[base]), y1 = Double(faceCorners[base + 1])
            let x2 = Double(faceCorners[base + 2]), y2 = Double(faceCorners[base + 3])
            result.faces.append(NormalizedRect(
                x: min(x1, x2) / Double(width),
                y: min(y1, y2) / Double(height),
                width: abs(x2 - x1) / Double(width),
                height: abs(y2 - y1) / Double(height)
            ))
        }
        return result
    }
}
