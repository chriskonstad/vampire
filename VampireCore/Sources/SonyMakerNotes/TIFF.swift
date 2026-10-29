import Foundation

/// A minimal TIFF/IFD walker — just enough structure to navigate an ARW head:
/// IFD0 → ExifIFD → MakerNote. Ported in spirit from exiftool's IFD handling;
/// we deliberately do not try to be a general TIFF library.
enum TIFF {
    /// TIFF field types we can size. Unknown types are skipped, not fatal —
    /// tag layout varies by Sony model/firmware and we must not choke on it.
    enum FieldType: UInt16 {
        case byte = 1
        case ascii = 2
        case short = 3
        case long = 4
        case rational = 5
        case sbyte = 6
        case undefined = 7
        case sshort = 8
        case slong = 9
        case srational = 10
        case float = 11
        case double = 12

        var byteSize: Int {
            switch self {
            case .byte, .ascii, .sbyte, .undefined: return 1
            case .short, .sshort: return 2
            case .long, .slong, .float: return 4
            case .rational, .srational, .double: return 8
            }
        }
    }

    struct Entry {
        let tag: UInt16
        let type: FieldType
        let count: Int
        /// Absolute offset (within the TIFF buffer) of the entry's value bytes.
        /// Values ≤4 bytes are stored inline in the entry; larger ones via pointer.
        let valueOffset: Int
    }

    struct IFD {
        let entries: [Entry]
        let nextIFDOffset: Int

        func entry(tag: UInt16) -> Entry? {
            entries.first { $0.tag == tag }
        }
    }

    /// Validates the TIFF header and returns a reader positioned over the whole buffer.
    /// ARW is standard TIFF: "II"/"MM" + magic 42.
    static func reader(forTIFFData data: Data) throws -> ByteReader {
        guard data.count >= 8 else { throw ARWParseError.truncated(needed: 8) }
        let endianness: ByteReader.Endianness
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): endianness = .little
        case (0x4D, 0x4D): endianness = .big
        default: throw ARWParseError.notTIFF
        }
        let reader = ByteReader(data: data, endianness: endianness)
        guard try reader.uint16(at: 2) == 42 else { throw ARWParseError.notTIFF }
        return reader
    }

    static func firstIFDOffset(in reader: ByteReader) throws -> Int {
        Int(try reader.uint32(at: 4))
    }

    /// Parses one IFD. `entryValueBase` is added to value pointers — 0 for
    /// normal TIFF IFDs where pointers are relative to the TIFF header.
    static func parseIFD(in reader: ByteReader, at offset: Int, entryValueBase: Int = 0) throws -> IFD {
        let entryCount = Int(try reader.uint16(at: offset))
        guard entryCount < 0x1000 else {
            throw ARWParseError.malformed("implausible IFD entry count \(entryCount)")
        }
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for i in 0 ..< entryCount {
            let entryOffset = offset + 2 + i * 12
            let tag = try reader.uint16(at: entryOffset)
            let rawType = try reader.uint16(at: entryOffset + 2)
            guard let type = FieldType(rawValue: rawType) else { continue }
            let count = Int(try reader.uint32(at: entryOffset + 4))
            let byteLength = type.byteSize * count
            let valueOffset: Int
            if byteLength <= 4 {
                valueOffset = entryOffset + 8
            } else {
                valueOffset = Int(try reader.uint32(at: entryOffset + 8)) + entryValueBase
            }
            entries.append(Entry(tag: tag, type: type, count: count, valueOffset: valueOffset))
        }
        let next = Int(try reader.uint32(at: offset + 2 + entryCount * 12))
        return IFD(entries: entries, nextIFDOffset: next)
    }

    /// Reads an entry's values as unsigned integers (BYTE/SHORT/LONG family).
    /// Signed types are accepted and bit-cast, matching how exiftool tolerates
    /// loose typing in maker notes.
    static func unsignedValues(of entry: Entry, in reader: ByteReader) throws -> [UInt32] {
        var values: [UInt32] = []
        values.reserveCapacity(entry.count)
        for i in 0 ..< entry.count {
            let at = entry.valueOffset + i * entry.type.byteSize
            switch entry.type {
            case .byte, .sbyte, .undefined:
                values.append(UInt32(try reader.uint8(at: at)))
            case .short, .sshort:
                values.append(UInt32(try reader.uint16(at: at)))
            case .long, .slong:
                values.append(try reader.uint32(at: at))
            default:
                throw ARWParseError.malformed("tag 0x\(String(entry.tag, radix: 16)) has non-integer type")
            }
        }
        return values
    }

    /// Reads an entry's payload as 16-bit unsigned values regardless of its
    /// declared type. Sony writes some tags as UNDEFINED blobs that are
    /// actually int16u arrays (e.g. 0x2037 FocusFrameSize, undef[6] = 3 shorts).
    static func uint16Values(of entry: Entry, in reader: ByteReader) throws -> [UInt16] {
        let byteLength = entry.type.byteSize * entry.count
        var values: [UInt16] = []
        values.reserveCapacity(byteLength / 2)
        for i in 0 ..< byteLength / 2 {
            values.append(try reader.uint16(at: entry.valueOffset + i * 2))
        }
        return values
    }

    static func asciiValue(of entry: Entry, in reader: ByteReader) throws -> String {
        try reader.ascii(at: entry.valueOffset, count: entry.count)
    }
}
