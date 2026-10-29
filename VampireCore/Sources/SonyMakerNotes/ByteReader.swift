import Foundation

/// Errors from parsing the head of an ARW file.
///
/// `.truncated` is special: it means the structure points past the end of the
/// bytes we have so far. When parsing a streamed head-of-file read, the caller
/// should fetch more bytes and retry. Every other case is a malformed file.
public enum ARWParseError: Error, Equatable {
    /// The requested range lies beyond the provided data; more of the file may satisfy it.
    case truncated(needed: Int)
    case notTIFF
    case malformed(String)
}

/// Bounds-checked, endian-aware reader over an in-memory head-of-file buffer.
struct ByteReader {
    enum Endianness {
        case little
        case big
    }

    let data: Data
    let endianness: Endianness

    /// `data` may be sliced; all offsets in this reader are relative to its start.
    init(data: Data, endianness: Endianness) {
        // Rebase so integer offsets are absolute into the buffer regardless of slicing.
        self.data = Data(data)
        self.endianness = endianness
    }

    var count: Int { data.count }

    func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else {
            throw ARWParseError.malformed("negative offset or count")
        }
        guard offset + count <= data.count else {
            throw ARWParseError.truncated(needed: offset + count)
        }
        return data.subdata(in: offset ..< offset + count)
    }

    func uint8(at offset: Int) throws -> UInt8 {
        try bytes(at: offset, count: 1)[0]
    }

    func uint16(at offset: Int) throws -> UInt16 {
        let b = try bytes(at: offset, count: 2)
        let value = b.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        return endianness == .little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        let b = try bytes(at: offset, count: 4)
        let value = b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return endianness == .little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    func int16(at offset: Int) throws -> Int16 {
        Int16(bitPattern: try uint16(at: offset))
    }

    func int32(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset))
    }

    /// ASCII string of `count` bytes, trimmed at the first NUL.
    func ascii(at offset: Int, count: Int) throws -> String {
        let raw = try bytes(at: offset, count: count)
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}
