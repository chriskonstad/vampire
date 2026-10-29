import Foundation

/// The PTP/IP connection handshake. The command channel opens with an
/// InitCommandRequest (our GUID + host name); the camera answers
/// InitCommandAck (its connection number, GUID, name). The event channel then
/// sends InitEventRequest carrying that connection number.
public enum PTPHandshake {
    /// 16-byte initiator GUID + host name, UTF-16LE null-terminated, + protocol
    /// version. The GUID just needs to be stable per installation.
    public static func initCommandRequest(guid: Data, hostName: String,
                                          protocolVersion: UInt32 = 0x0001_0000) -> PTPIPPacket {
        precondition(guid.count == 16, "PTP/IP GUID must be 16 bytes")
        var w = PTPWriter()
        w.bytes(guid)
        w.utf16zString(hostName)
        w.u32(protocolVersion)
        return PTPIPPacket(type: .initCommandRequest, payload: w.data)
    }

    public struct CommandAck: Equatable {
        public let connectionNumber: UInt32
        public let cameraGUID: Data
        public let cameraName: String
        public let protocolVersion: UInt32
    }

    public static func parseCommandAck(_ packet: PTPIPPacket) throws -> CommandAck {
        guard packet.type == .initCommandAck else {
            throw PTPWireError.malformed("expected InitCommandAck, got \(packet.type)")
        }
        var r = PTPReader(packet.payload)
        let conn = try r.u32()
        let guid = try r.bytes(16)
        let name = try r.utf16zString()
        let version = r.remaining >= 4 ? try r.u32() : 0
        return CommandAck(connectionNumber: conn, cameraGUID: guid,
                          cameraName: name, protocolVersion: version)
    }

    /// Event channel request: just the connection number from the ack.
    public static func initEventRequest(connectionNumber: UInt32) -> PTPIPPacket {
        var w = PTPWriter()
        w.u32(connectionNumber)
        return PTPIPPacket(type: .initEventRequest, payload: w.data)
    }
}
