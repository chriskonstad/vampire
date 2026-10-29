import Foundation

/// A framed PTP/IP packet: `[u32 length][u32 type][payload]`. This layer only
/// does framing; the payload is interpreted by the operation/data/handshake
/// types.
public struct PTPIPPacket: Equatable {
    public let type: PTPIPPacketType
    public let payload: Data

    public init(type: PTPIPPacketType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    /// Serializes to the wire with the length-inclusive header.
    public func encoded() -> Data {
        var w = PTPWriter()
        w.u32(UInt32(8 + payload.count)) // length includes the 8-byte header
        w.u32(type.rawValue)
        w.bytes(payload)
        return w.data
    }

    /// Parses one packet from the front of `buffer`. Returns nil (not an
    /// error) when fewer than a whole packet's bytes are present yet — the
    /// socket reader loops until a full frame arrives. Throws only on a
    /// structurally invalid frame.
    public static func parse(_ buffer: Data) throws -> (packet: PTPIPPacket, consumed: Int)? {
        guard buffer.count >= 8 else { return nil }
        var r = PTPReader(buffer)
        let length = Int(try r.u32())
        guard length >= 8, length <= 64 * 1024 * 1024 else {
            throw PTPWireError.malformed("implausible PTP/IP packet length \(length)")
        }
        guard buffer.count >= length else { return nil } // wait for more bytes
        let rawType = try r.u32()
        guard let type = PTPIPPacketType(rawValue: rawType) else {
            throw PTPWireError.malformed("unknown PTP/IP packet type \(rawType)")
        }
        let payload = try r.bytes(length - 8)
        return (PTPIPPacket(type: type, payload: payload), length)
    }
}

/// One PTP operation to send (Operation Request packet payload).
public struct PTPOperationRequest {
    public enum DataPhase: UInt32 { case none = 1, dataToCamera = 2 }

    public let operation: PTPOperation
    public let transactionID: UInt32
    public let parameters: [UInt32]
    public let dataPhase: DataPhase

    public init(_ operation: PTPOperation, transactionID: UInt32,
                parameters: [UInt32] = [], dataPhase: DataPhase = .none) {
        self.operation = operation
        self.transactionID = transactionID
        self.parameters = parameters
        self.dataPhase = dataPhase
    }

    public func packet() -> PTPIPPacket {
        var w = PTPWriter()
        w.u32(dataPhase.rawValue)
        w.u16(operation.rawValue)
        w.u32(transactionID)
        for p in parameters.prefix(5) { w.u32(p) }
        return PTPIPPacket(type: .operationRequest, payload: w.data)
    }
}

/// Parsed Operation Response packet payload.
public struct PTPOperationResponse: Equatable {
    public let code: UInt16
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public var response: PTPResponse? { PTPResponse(rawValue: code) }
    public var isSuccess: Bool { code == PTPResponse.ok.rawValue }

    public init(from payload: Data) throws {
        var r = PTPReader(payload)
        code = try r.u16()
        transactionID = try r.u32()
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(try r.u32()) }
        parameters = params
    }

    public init(code: UInt16, transactionID: UInt32, parameters: [UInt32] = []) {
        self.code = code; self.transactionID = transactionID; self.parameters = parameters
    }
}
