import Foundation

/// GetDeviceInfo dataset: who the camera is and which operations it supports
/// *in its current mode*. Sony exposes different op sets for PC Remote vs
/// content transfer, so this is how we tell which mode we actually landed in.
public struct PTPDeviceInfo: Equatable {
    public let vendorExtensionID: UInt32
    public let vendorExtension: String
    public let operations: [UInt16]
    public let imageFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String

    public func supports(_ op: PTPOperation) -> Bool { operations.contains(op.rawValue) }

    public init(from data: Data) throws {
        var r = PTPReader(data)
        _ = try r.u16()                      // standard version
        vendorExtensionID = try r.u32()
        _ = try r.u16()                      // vendor extension version
        vendorExtension = try r.ptpString()
        _ = try r.u16()                      // functional mode
        operations = try Self.u16Array(&r)
        _ = try Self.u16Array(&r)            // events
        _ = try Self.u16Array(&r)            // device properties
        _ = try Self.u16Array(&r)            // capture formats
        imageFormats = try Self.u16Array(&r)
        manufacturer = try r.ptpString()
        model = try r.ptpString()
        deviceVersion = try r.ptpString()
    }

    private static func u16Array(_ r: inout PTPReader) throws -> [UInt16] {
        let count = Int(try r.u32())
        guard count <= 10_000 else { throw PTPWireError.malformed("implausible PTP array count \(count)") }
        return try (0 ..< count).map { _ in try r.u16() }
    }
}
