import XCTest
@testable import PTP

final class PTPCodecTests: XCTestCase {

    // MARK: - Packet framing

    func testPacketRoundTrip() throws {
        let packet = PTPIPPacket(type: .operationRequest, payload: Data([1, 2, 3, 4]))
        let wire = packet.encoded()
        // length-inclusive header: 8 + 4 = 12, little-endian
        XCTAssertEqual(Array(wire.prefix(4)), [12, 0, 0, 0])
        XCTAssertEqual(Array(wire[4..<8]), [6, 0, 0, 0]) // type 6

        let parsed = try XCTUnwrap(try PTPIPPacket.parse(wire))
        XCTAssertEqual(parsed.consumed, 12)
        XCTAssertEqual(parsed.packet, packet)
    }

    func testParseWaitsForFullFrame() throws {
        let wire = PTPIPPacket(type: .data, payload: Data(count: 100)).encoded()
        // Only part of the frame arrived yet.
        XCTAssertNil(try PTPIPPacket.parse(wire.prefix(40)))
        XCTAssertNil(try PTPIPPacket.parse(wire.prefix(7)))
        XCTAssertNotNil(try PTPIPPacket.parse(wire))
    }

    func testParseHandlesBackToBackPackets() throws {
        var stream = PTPIPPacket(type: .startData, payload: Data([9])).encoded()
        stream += PTPIPPacket(type: .endData, payload: Data([12])).encoded()
        let first = try XCTUnwrap(try PTPIPPacket.parse(stream))
        XCTAssertEqual(first.packet.type, .startData)
        let rest = stream.suffix(from: stream.startIndex + first.consumed)
        let second = try XCTUnwrap(try PTPIPPacket.parse(Data(rest)))
        XCTAssertEqual(second.packet.type, .endData)
    }

    func testMalformedLengthThrows() {
        var w = PTPWriter(); w.u32(4); w.u32(6) // length 4 < header size 8
        XCTAssertThrowsError(try PTPIPPacket.parse(w.data))
    }

    // MARK: - Operation request

    func testGetPartialObjectRequestEncoding() throws {
        // Fetch 352435 bytes at offset 192674 of handle 0xABCD — the embedded
        // preview transfer at the heart of wireless culling.
        let req = PTPOperationRequest(.getPartialObject, transactionID: 7,
                                      parameters: [0xABCD, 192674, 352435])
        let payload = req.packet().payload
        var r = PTPReader(payload)
        XCTAssertEqual(try r.u32(), 1)            // data phase: none/data-in
        XCTAssertEqual(try r.u16(), 0x101B)       // GetPartialObject
        XCTAssertEqual(try r.u32(), 7)            // transaction id
        XCTAssertEqual(try r.u32(), 0xABCD)
        XCTAssertEqual(try r.u32(), 192674)
        XCTAssertEqual(try r.u32(), 352435)
    }

    func testOperationResponseDecoding() throws {
        var w = PTPWriter()
        w.u16(PTPResponse.ok.rawValue); w.u32(7); w.u32(42)
        let resp = try PTPOperationResponse(from: w.data)
        XCTAssertTrue(resp.isSuccess)
        XCTAssertEqual(resp.response, .ok)
        XCTAssertEqual(resp.transactionID, 7)
        XCTAssertEqual(resp.parameters, [42])
    }

    func testFailureResponseSurfaced() throws {
        var w = PTPWriter(); w.u16(PTPResponse.deviceBusy.rawValue); w.u32(3)
        let resp = try PTPOperationResponse(from: w.data)
        XCTAssertFalse(resp.isSuccess)
        XCTAssertEqual(resp.response, .deviceBusy)
    }

    // MARK: - Data phase reassembly

    func testMultiPacketDataPhaseReassembles() throws {
        var asm = PTPDataPhaseAssembler(transactionID: 7)
        var start = PTPWriter(); start.u32(7); start.u64(6) // total 6 bytes
        var d1 = PTPWriter(); d1.u32(7); d1.bytes(Data([0xAA, 0xBB]))
        var d2 = PTPWriter(); d2.u32(7); d2.bytes(Data([0xCC, 0xDD]))
        var end = PTPWriter(); end.u32(7); end.bytes(Data([0xEE, 0xFF]))

        XCTAssertEqual(try asm.accept(PTPIPPacket(type: .startData, payload: start.data)), .accepted)
        XCTAssertEqual(try asm.accept(PTPIPPacket(type: .data, payload: d1.data)), .accepted)
        XCTAssertEqual(try asm.accept(PTPIPPacket(type: .data, payload: d2.data)), .accepted)
        XCTAssertEqual(try asm.accept(PTPIPPacket(type: .endData, payload: end.data)), .completed)

        XCTAssertTrue(asm.isComplete)
        XCTAssertEqual(asm.expectedLength, 6)
        XCTAssertEqual(Array(asm.data), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertFalse(asm.isShort)
    }

    func testShortTransferDetected() throws {
        var asm = PTPDataPhaseAssembler(transactionID: 1)
        var start = PTPWriter(); start.u32(1); start.u64(1000)
        var end = PTPWriter(); end.u32(1); end.bytes(Data([1, 2, 3]))
        _ = try asm.accept(PTPIPPacket(type: .startData, payload: start.data))
        _ = try asm.accept(PTPIPPacket(type: .endData, payload: end.data))
        XCTAssertTrue(asm.isShort) // promised 1000, delivered 3
    }

    // MARK: - Handshake

    func testInitCommandHandshakeRoundTrip() throws {
        let guid = Data((0 ..< 16).map { UInt8($0) })
        let reqPacket = PTPHandshake.initCommandRequest(guid: guid, hostName: "Vampire")
        XCTAssertEqual(reqPacket.type, .initCommandRequest)
        var rr = PTPReader(reqPacket.payload)
        XCTAssertEqual(Array(try rr.bytes(16)), Array(guid))
        XCTAssertEqual(try rr.utf16zString(), "Vampire")

        // Build a camera ack and parse it back.
        var w = PTPWriter()
        w.u32(1)                                   // connection number
        w.bytes(Data((16 ..< 32).map { UInt8($0) })) // camera guid
        w.utf16zString("ILCE-7RM5")
        w.u32(0x0001_0000)
        let ack = try PTPHandshake.parseCommandAck(PTPIPPacket(type: .initCommandAck, payload: w.data))
        XCTAssertEqual(ack.connectionNumber, 1)
        XCTAssertEqual(ack.cameraName, "ILCE-7RM5")
        XCTAssertEqual(ack.protocolVersion, 0x0001_0000)
    }

    // MARK: - Datasets

    func testU32ArrayParsing() throws {
        var w = PTPWriter(); w.u32(3); w.u32(0x100); w.u32(0x101); w.u32(0x102)
        XCTAssertEqual(try PTPDataset.u32Array(w.data), [0x100, 0x101, 0x102])
    }

    func testObjectInfoParsesFilenameAndFormat() throws {
        var w = PTPWriter()
        w.u32(0x00010001)          // storage id
        w.u16(0xB101)              // sony raw format
        w.u16(0)                   // protection
        w.u32(68_603_904)          // compressed size (file bytes)
        w.u16(0x3801); w.u32(11489) // thumb format + size
        w.u32(160); w.u32(120)      // thumb w/h
        w.u32(9504); w.u32(6336)    // image w/h
        w.u32(24); w.u32(0); w.u16(0); w.u32(0); w.u32(0) // depth, parent, assoc…
        // filename "DSC04319.ARW" as a PTP string (len incl. terminator)
        let name = "DSC04319.ARW"
        w.u8(UInt8(name.utf16.count + 1))
        for u in name.utf16 { w.u16(u) }
        w.u16(0)

        let info = try PTPObjectInfo(from: w.data)
        XCTAssertEqual(info.filename, "DSC04319.ARW")
        XCTAssertEqual(info.compressedSize, 68_603_904)
        XCTAssertEqual(info.imagePixWidth, 9504)
        XCTAssertTrue(info.isRAW)
        XCTAssertEqual(info.format, .sonyRAW)
    }

    func testDeviceInfoParsesOpsAndModel() throws {
        func str(_ s: String, into w: inout PTPWriter) {
            w.u8(UInt8(s.utf16.count + 1)); for u in s.utf16 { w.u16(u) }; w.u16(0)
        }
        var w = PTPWriter()
        w.u16(100); w.u32(0x11); w.u16(100)
        str("Sony PTP Extensions", into: &w)
        w.u16(0)
        w.u32(3); w.u16(0x1001); w.u16(0x101B); w.u16(0x9201)  // ops
        w.u32(0)                                              // events
        w.u32(1); w.u16(0x5001)                               // props
        w.u32(0)                                              // capture formats
        w.u32(2); w.u16(0x3801); w.u16(0xB101)                // image formats
        str("Sony Corporation", into: &w); str("ILCE-7RM5", into: &w); str("3.00", into: &w)

        let info = try PTPDeviceInfo(from: w.data)
        XCTAssertEqual(info.model, "ILCE-7RM5")
        XCTAssertEqual(info.vendorExtensionID, 0x11)
        XCTAssertTrue(info.supports(.getPartialObject))
        XCTAssertTrue(info.supports(.sonySDIOConnect))
        XCTAssertFalse(info.supports(.getThumb))
        XCTAssertEqual(info.imageFormats, [0x3801, 0xB101])
    }

    // MARK: - Truncation safety (bytes come off an untrusted socket)

    func testReaderThrowsOnTruncation() {
        var r = PTPReader(Data([1, 2]))
        XCTAssertThrowsError(try r.u32())
    }
}
