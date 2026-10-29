import XCTest
@testable import SonyMakerNotes

final class ARWHeadParserTests: XCTestCase {

    // MARK: - FocusLocation (tag 0x2027)

    func testParsesFocusLocationLittleEndian() throws {
        let head = TIFFBuilder.sonyARWHead(focusLocation: [9504, 6336, 4752, 3168])
        let metadata = try ARWHeadParser.parse(head: head)

        XCTAssertEqual(metadata.make, "SONY")
        XCTAssertEqual(metadata.model, "ILCE-7RM5")
        XCTAssertEqual(
            metadata.focusLocation,
            FocusLocation(imageWidth: 9504, imageHeight: 6336, x: 4752, y: 3168)
        )
        let point = try XCTUnwrap(metadata.focusLocation?.normalizedPoint)
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-9)
    }

    func testParsesFocusLocationBigEndian() throws {
        let head = TIFFBuilder.sonyARWHead(endianness: .big, focusLocation: [800, 600, 200, 150])
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertEqual(
            metadata.focusLocation,
            FocusLocation(imageWidth: 800, imageHeight: 600, x: 200, y: 150)
        )
    }

    func testParsesFocusLocationStoredAsLongType() throws {
        // Tag layout varies by firmware: accept LONG as well as SHORT.
        let head = TIFFBuilder.sonyARWHead(focusLocation: [9504, 6336, 100, 200], focusLocationType: 4)
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertEqual(metadata.focusLocation?.x, 100)
        XCTAssertEqual(metadata.focusLocation?.y, 200)
    }

    func testParsesFocusFrameSize() throws {
        // 0x2037 undef[6] = int16u[3]: width, height, unknown (fixture values).
        let head = TIFFBuilder.sonyARWHead(
            focusLocation: [9504, 6336, 4870, 2072],
            focusFrameSize: [297, 297, 257],
            makerNoteSignature: nil
        )
        let focus = try XCTUnwrap(ARWHeadParser.parse(head: head).focusLocation)
        XCTAssertEqual(focus.frameWidth, 297)
        XCTAssertEqual(focus.frameHeight, 297)

        let frame = try XCTUnwrap(focus.normalizedFrame)
        XCTAssertEqual(frame.width, 297.0 / 9504.0, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 297.0 / 6336.0, accuracy: 1e-9)
        // Centered on the focus point.
        XCTAssertEqual(frame.x + frame.width / 2, 4870.0 / 9504.0, accuracy: 1e-9)
        XCTAssertEqual(frame.y + frame.height / 2, 2072.0 / 6336.0, accuracy: 1e-9)
    }

    func testFrameSizeWithoutFocusLocationIsIgnored() throws {
        let head = TIFFBuilder.sonyARWHead(focusLocation: nil, focusFrameSize: [297, 297, 257])
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertNil(metadata.focusLocation)
        XCTAssertEqual(metadata.makerNote?.rawTagValues[0x2037], [297, 297, 257])
    }

    func testParsesSignaturelessMakerNote() throws {
        // A7RV-generation layout: no signature, bare IFD from byte 0
        // (matches fixtures/DSC04319.ARW).
        let head = TIFFBuilder.sonyARWHead(
            focusLocation: [9504, 6336, 4870, 2072],
            makerNoteSignature: nil
        )
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertEqual(
            metadata.focusLocation,
            FocusLocation(imageWidth: 9504, imageHeight: 6336, x: 4870, y: 2072)
        )
    }

    func testMissingFocusLocationIsNilNotError() throws {
        let head = TIFFBuilder.sonyARWHead(focusLocation: nil)
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertNotNil(metadata.makerNote)
        XCTAssertNil(metadata.focusLocation)
    }

    func testZeroDimensionFocusLocationHasNoNormalizedPoint() {
        // Seen on manual-focus frames: tag present, dimensions zeroed.
        let focus = FocusLocation(imageWidth: 0, imageHeight: 0, x: 0, y: 0)
        XCTAssertNil(focus.normalizedPoint)
    }

    // MARK: - Capture date

    func testCaptureDateIncludesSubseconds() throws {
        let head = TIFFBuilder.sonyARWHead(
            dateTimeOriginal: "2026:06:01 10:15:30",
            subSecTimeOriginal: "57"
        )
        let date = try XCTUnwrap(ARWHeadParser.parse(head: head).dateTimeOriginal)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.second, .nanosecond], from: date)
        XCTAssertEqual(components.second, 30)
        XCTAssertEqual(Double(components.nanosecond!) / 1e9, 0.57, accuracy: 0.001)
    }

    func testCaptureDateWithoutSubseconds() throws {
        let head = TIFFBuilder.sonyARWHead(subSecTimeOriginal: nil)
        XCTAssertNotNil(try ARWHeadParser.parse(head: head).dateTimeOriginal)
    }

    // MARK: - Robustness

    func testNonTIFFDataThrowsNotTIFF() {
        XCTAssertThrowsError(try ARWHeadParser.parse(head: Data("JPEGnope".utf8) + Data(count: 64))) {
            XCTAssertEqual($0 as? ARWParseError, .notTIFF)
        }
    }

    func testTruncatedHeadThrowsTruncated() throws {
        let full = TIFFBuilder.sonyARWHead()
        let truncated = full.prefix(full.count / 2)
        XCTAssertThrowsError(try ARWHeadParser.parse(head: Data(truncated))) { error in
            guard case ARWParseError.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testUnknownMakerNoteVendorIsSkippedNotFatal() throws {
        // A foreign maker note must not cost us the EXIF we already parsed.
        let head = TIFFBuilder.sonyARWHead(makerNoteSignature: "NIKON SCAN \0")
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertNil(metadata.makerNote)
        XCTAssertNotNil(metadata.dateTimeOriginal)
    }

    func testUnknownMakerNoteTagsAreCapturedNotFatal() throws {
        let b = TIFFBuilder(endianness: .little)
        let head = TIFFBuilder.sonyARWHead(extraMakerNoteTags: [
            .init(tag: 0xB000, type: 3, count: 2, payload: b.shortValues([2, 0])),
        ])
        let metadata = try ARWHeadParser.parse(head: head)
        XCTAssertEqual(metadata.makerNote?.rawTagValues[0xB000], [2, 0])
        XCTAssertNotNil(metadata.focusLocation)
    }

    // MARK: - Streaming session

    func testHeadParseSessionNeedsMoreDataThenSucceeds() {
        let full = TIFFBuilder.sonyARWHead()
        let session = HeadParseSession()

        let mid = full.count / 2
        guard case .needMoreData = session.ingest(full.prefix(mid)) else {
            return XCTFail("half the head should not parse")
        }
        guard case .done(let metadata) = session.ingest(full.suffix(from: mid)) else {
            return XCTFail("full head should parse")
        }
        XCTAssertNotNil(metadata.focusLocation)
    }

    func testHeadParseSessionGivesUpAtCap() {
        // A TIFF whose IFD0 points far beyond the cap: keep feeding junk and
        // the session must fail rather than buffer forever.
        var data = Data([0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x0F]) // IFD0 at ~256MB
        let session = HeadParseSession(maxHeadLength: 4096)

        guard case .needMoreData = session.ingest(data) else {
            return XCTFail("should ask for more first")
        }
        guard case .failed = session.ingest(Data(count: 8192)) else {
            return XCTFail("should give up past the cap")
        }
    }
}
