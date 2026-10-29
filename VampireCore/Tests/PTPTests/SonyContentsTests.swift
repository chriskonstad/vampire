import XCTest
@testable import PTP

/// Sony remote-transfer layouts, built byte-for-byte per alpha2go's
/// docs/protocol.md (a6700-verified).
final class SonyContentsTests: XCTestCase {
    private func file(_ w: inout PTPWriter, id: UInt16, path: String, format: UInt32,
                      size: UInt64, dims: (UInt32, UInt32)?) {
        w.u16(id); w.u16(0)
        let bytes = Data(path.utf8) + [0]
        w.u32(UInt32(bytes.count)); w.bytes(bytes)
        w.u32(format); w.u64(size)
        w.bytes(Data(repeating: 0xAB, count: 32))       // UMID
        if let (fw, fh) = dims { w.u32(1); w.u32(fw); w.u32(fh) } else { w.u32(0) }
        w.u32(0); w.u32(0)                               // no video/audio params
    }

    private func listReply() -> Data {
        var w = PTPWriter()
        w.u32(100); w.bytes(Data(repeating: 0, count: 0x90 - 4))
        w.u32(2)
        // RAW+JPEG pair, rated 3 stars, protected, one shot mark byte.
        w.u32(1); w.u32(0x0002_0001); w.u32(100); w.u32(4319); w.u32(0); w.u32(0); w.u32(1)
        w.u64(1_761_700_000_000); w.u64(0); w.u64(0); w.u64(0)
        w.u32(3); w.u32(1); w.u32(1)
        w.u32(1); w.u8(7)
        w.u32(2)
        file(&w, id: 1, path: "A:/DCIM/100MSDCF/DSC04319.ARW", format: 0xB101,
             size: 68_603_904, dims: (9504, 6336))
        file(&w, id: 2, path: "A:/DCIM/100MSDCF/DSC04319.JPG", format: 0x3801,
             size: 12_000_000, dims: (9504, 6336))
        // Unrated RAW only.
        w.u32(1); w.u32(0x0002_0002); w.u32(100); w.u32(4320); w.u32(0); w.u32(0); w.u32(1)
        w.u64(1_761_700_000_500); w.u64(0); w.u64(0); w.u64(0)
        w.u32(0); w.u32(0); w.u32(1)
        w.u32(0)
        w.u32(1)
        file(&w, id: 1, path: "A:/DCIM/100MSDCF/DSC04320.ARW", format: 0xB101,
             size: 68_000_000, dims: nil)
        return w.data
    }

    func testParsesContentsWithPairsRatingsAndProtect() throws {
        let contents = try SonyRemoteTransfer.parseContentsList(listReply())
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0].contentID, 0x0002_0001)
        XCTAssertEqual(contents[0].rating, 3)
        XCTAssertTrue(contents[0].isProtected)
        XCTAssertEqual(contents[0].files.map(\.filename), ["DSC04319.ARW", "DSC04319.JPG"])
        XCTAssertTrue(contents[0].files[0].isRAW)
        XCTAssertEqual(contents[0].files[0].size, 68_603_904)
        XCTAssertEqual(contents[0].files[0].pixelWidth, 9504)
        XCTAssertEqual(contents[1].createdUTCms, 1_761_700_000_500)
        XCTAssertEqual(contents[1].rating, 0)
        XCTAssertFalse(contents[1].isProtected)
        XCTAssertEqual(contents[1].files[0].pixelWidth, 0)
    }

    func testTruncatedListThrows() {
        let data = listReply()
        XCTAssertThrowsError(try SonyRemoteTransfer.parseContentsList(data.prefix(data.count - 10)))
    }

    func testListParametersSplitCursor() {
        let p = SonyRemoteTransfer.contentsListParameters(cursor: 0x0000_0199_2A3B_4C5D, slot: 1)
        XCTAssertEqual(p, [0x2A3B_4C5D, 0x199, 100, 1, 0])
        XCTAssertEqual(SonyRemoteTransfer.contentsListParameters(cursor: 0, slot: 2), [0, 0, 100, 2, 0])
    }

    func testDataParametersMarkLastChunk() {
        let mid = SonyRemoteTransfer.contentsDataParameters(
            contentID: 0x20001, slot: 1, fileID: 1, offset: 0, size: 262_144, fileSize: 68_603_904)
        XCTAssertEqual(mid, [0x20001, 0x0100_0001, 0, 0, 262_144])
        let last = SonyRemoteTransfer.contentsDataParameters(
            contentID: 0x20001, slot: 2, fileID: 3, offset: 0x1_0000_0000, size: 4096, fileSize: 0x1_0000_1000)
        XCTAssertEqual(last, [0x20001, 0x0200_0003, 0, 1, 4096 | 0x8000_0000])
    }
}
