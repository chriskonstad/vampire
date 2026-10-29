import Foundation

/// PTP/IP packet types (ISO 15740 IP extension). Every packet on the wire is
/// `[u32 length][u32 type][payload]`, length-inclusive, little-endian.
public enum PTPIPPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case operationRequest = 6
    case operationResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancel = 11
    case endData = 12
    case probeRequest = 13   // ping
    case probeResponse = 14  // pong
}

/// PTP operation codes. Only the subset the culling flow needs — plus
/// `deleteObject`, defined ONLY so the app can be statically checked never to
/// send it (hard rule: we never delete off the card).
public enum PTPOperation: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case deleteObject = 0x100B   // NEVER sent — see CameraTransport.
    case getPartialObject = 0x101B
    // Sony vendor ops: the SDIO handshake some Sony modes need before they
    // expose storage (sequence from libgphoto2's Sony support).
    case sonySDIOConnect = 0x9201
    case sonyGetSDIOExtDeviceInfo = 0x9202
    // Sony remote transfer: card access while the camera UI stays usable.
    // Layouts per alpha2go docs/protocol.md (a6700-verified, A7RV-confirmed).
    // Sony's content delete (0x9250) is deliberately NOT defined here.
    case sonyGetCapturedDateList = 0x923B
    case sonyGetContentsInfoList = 0x923C
    case sonyGetContentsData = 0x923D
    case sonyGetContentsCompressedData = 0x923E
}

/// PTP response codes (0x20xx). `ok` is success; everything else is a fault to
/// surface to the user.
public enum PTPResponse: UInt16, Sendable, Equatable {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case invalidTransactionID = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case storeFull = 0x200C
    case accessDenied = 0x200F
    case deviceBusy = 0x2019
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E

    public var isSuccess: Bool { self == .ok }
}

/// PTP object-format codes we care about distinguishing.
public enum PTPObjectFormat: UInt16, Sendable {
    case association = 0x3001  // folder
    case exifJPEG = 0x3801
    case tiff = 0x380D
    case sonyRAW = 0xB101      // Sony ARW (vendor-defined)
    case unknown = 0x0000
}
