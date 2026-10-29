import Foundation

/// Reassembles a PTP data phase. A data-in operation (GetObject, GetThumb,
/// GetPartialObject…) answers with a StartData packet (carrying the total
/// length), zero or more Data packets, and an EndData packet. This accumulates
/// the payloads and reports completion so the socket loop knows when to stop.
public struct PTPDataPhaseAssembler {
    public private(set) var expectedLength: UInt64?
    public private(set) var data = Data()
    public private(set) var isComplete = false
    public let transactionID: UInt32

    public init(transactionID: UInt32) {
        self.transactionID = transactionID
    }

    public enum Step: Equatable { case accepted, completed, ignored }

    /// Feed one parsed PTP/IP packet. Non-data packets for this phase are
    /// ignored (returns `.ignored`); EndData flips `isComplete`.
    public mutating func accept(_ packet: PTPIPPacket) throws -> Step {
        switch packet.type {
        case .startData:
            var r = PTPReader(packet.payload)
            _ = try r.u32()              // transactionID
            expectedLength = try r.u64()
            return .accepted
        case .data:
            var r = PTPReader(packet.payload)
            _ = try r.u32()
            data.append(try r.bytes(r.remaining))
            return .accepted
        case .endData:
            var r = PTPReader(packet.payload)
            _ = try r.u32()
            data.append(try r.bytes(r.remaining))
            isComplete = true
            return .completed
        default:
            return .ignored
        }
    }

    /// True when the camera delivered fewer bytes than it promised — a partial
    /// transfer the caller should treat as a failure.
    public var isShort: Bool {
        guard isComplete, let expected = expectedLength else { return false }
        return UInt64(data.count) < expected
    }
}
