import XCTest
@testable import SonyMakerNotes

final class FujiParserTests: XCTestCase {

    func testParsesFujiJPEGFocusAndFaces() throws {
        let head = TIFFBuilder.fujiJPEGHead()
        let metadata = try CameraHeadParser.parse(head: head)

        XCTAssertEqual(metadata.make, "FUJIFILM")
        XCTAssertEqual(metadata.model, "X-T5")
        XCTAssertEqual(metadata.pixelWidth, 7728)
        XCTAssertEqual(metadata.pixelHeight, 5152)

        let focus = try XCTUnwrap(metadata.focusLocation)
        XCTAssertEqual(
            focus,
            FocusLocation(imageWidth: 7728, imageHeight: 5152, x: 6052, y: 2063)
        )

        let face = try XCTUnwrap(metadata.cameraFaces.first)
        XCTAssertEqual(face.x, 5204.0 / 7728.0, accuracy: 1e-9)
        XCTAssertEqual(face.y, 1366.0 / 5152.0, accuracy: 1e-9)
        XCTAssertEqual(face.width, (7207.0 - 5204.0) / 7728.0, accuracy: 1e-9)
        XCTAssertEqual(face.height, (2961.0 - 1366.0) / 5152.0, accuracy: 1e-9)
    }

    func testParsesRAFContainer() throws {
        let raf = TIFFBuilder.rafContainer(wrapping: TIFFBuilder.fujiJPEGHead())
        let metadata = try CameraHeadParser.parse(head: raf)
        XCTAssertEqual(metadata.model, "X-T5")
        XCTAssertNotNil(metadata.focusLocation)
    }

    func testNoFacesIsEmptyNotError() throws {
        let head = TIFFBuilder.fujiJPEGHead(faceCorners: [])
        let metadata = try CameraHeadParser.parse(head: head)
        XCTAssertTrue(metadata.cameraFaces.isEmpty)
        XCTAssertNotNil(metadata.focusLocation)
    }

    func testTruncatedFujiHeadAsksForMore() {
        let full = TIFFBuilder.rafContainer(wrapping: TIFFBuilder.fujiJPEGHead())
        let session = HeadParseSession()
        let mid = 100 // inside the RAF header, before the embedded JPEG
        guard case .needMoreData = session.ingest(full.prefix(mid)) else {
            return XCTFail("partial RAF head should ask for more")
        }
        guard case .done(let metadata) = session.ingest(full.suffix(from: mid)) else {
            return XCTFail("full RAF head should parse")
        }
        XCTAssertEqual(metadata.model, "X-T5")
    }

    func testSonyPathStillWorks() throws {
        // Dispatch must not break the existing TIFF/ARW path.
        let head = TIFFBuilder.sonyARWHead()
        let metadata = try CameraHeadParser.parse(head: head)
        XCTAssertEqual(metadata.model, "ILCE-7RM5")
        XCTAssertNotNil(metadata.focusLocation)
    }
}
