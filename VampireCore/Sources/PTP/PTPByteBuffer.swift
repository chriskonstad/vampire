import Foundation

/// Little-endian reader/writer for PTP/IP wire data. PTP is little-endian on
/// the wire regardless of host. Bounds-checked reads throw rather than crash,
/// because the bytes come off a socket from a camera we don't control.
public enum PTPWireError: Error, Equatable {
    case truncated(needed: Int, have: Int)
    case malformed(String)
}

public struct PTPReader {
    public let data: Data
    public private(set) var cursor: Int

    public init(_ data: Data, at offset: Int = 0) {
        // Rebase so cursor arithmetic is independent of the slice's startIndex.
        self.data = Data(data)
        self.cursor = offset
    }

    public var remaining: Int { data.count - cursor }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, cursor + count <= data.count else {
            throw PTPWireError.truncated(needed: count, have: data.count - cursor)
        }
        defer { cursor += count }
        return data.subdata(in: cursor ..< cursor + count)
    }

    public mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    public mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    public mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    public mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | (hi << 32)
    }

    /// PTP string: u8 length (in UTF-16 code units incl. terminator), then
    /// UTF-16LE characters. Length 0 means empty.
    public mutating func ptpString() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        let raw = try bytes(count * 2)
        var units: [UInt16] = []
        for i in stride(from: 0, to: raw.count, by: 2) {
            let u = UInt16(raw[i]) | (UInt16(raw[i+1]) << 8)
            if u == 0 { break }
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Reads a null-terminated UTF-16LE string (used in the init handshake,
    /// which is NOT length-prefixed like PTP dataset strings).
    public mutating func utf16zString() throws -> String {
        var units: [UInt16] = []
        while remaining >= 2 {
            let u = try u16()
            if u == 0 { break }
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

public struct PTPWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    public mutating func u32(_ v: UInt32) {
        for s in stride(from: 0, through: 24, by: 8) { data.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }
    public mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFFFFFF)); u32(UInt32(v >> 32)) }
    public mutating func bytes(_ d: Data) { data.append(d) }

    /// Null-terminated UTF-16LE (init handshake style).
    public mutating func utf16zString(_ s: String) {
        for u in s.utf16 { u16(u) }
        u16(0)
    }
}
