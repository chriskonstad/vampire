import XCTest
@testable import SonyMakerNotes

final class DisplayOrientationTests: XCTestCase {
    /// Real A7RV portrait frame (DSC05518, orientation 8): AF at sensor
    /// (3445, 4778) of 9504×6336 shows at (0.754, 0.638) once upright.
    func testPortraitOrientation8MapsAFPoint() {
        let p = DisplayOrientation.point((3445.0 / 9504, 4778.0 / 6336), exif: 8)
        XCTAssertEqual(p.x, 0.754, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.638, accuracy: 0.001)
    }

    func testOrientation6And3() {
        let p6 = DisplayOrientation.point((0.2, 0.1), exif: 6)
        XCTAssertEqual(p6.x, 0.9, accuracy: 1e-9); XCTAssertEqual(p6.y, 0.2, accuracy: 1e-9)
        let p3 = DisplayOrientation.point((0.2, 0.1), exif: 3)
        XCTAssertEqual(p3.x, 0.8, accuracy: 1e-9); XCTAssertEqual(p3.y, 0.9, accuracy: 1e-9)
        let p1 = DisplayOrientation.point((0.2, 0.1), exif: nil)
        XCTAssertEqual(p1.x, 0.2); XCTAssertEqual(p1.y, 0.1)
    }

    func testRectSwapsAxesWhenRotated() {
        let r = DisplayOrientation.rect(NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), exif: 8)
        XCTAssertEqual(r.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.3, accuracy: 1e-9)
    }

    /// Same real frame as above, through FocusLocation: point and AF box land
    /// where the free functions put them, with dimensions swapped.
    func testFocusLocationOrientation8MatchesPointMapping() {
        let sensor = FocusLocation(imageWidth: 9504, imageHeight: 6336, x: 3445, y: 4778,
                                   frameWidth: 475, frameHeight: 476)
        let upright = sensor.displayOriented(exif: 8)
        XCTAssertEqual(upright.imageWidth, 6336)
        XCTAssertEqual(upright.imageHeight, 9504)
        XCTAssertEqual(upright.frameWidth, 476)
        XCTAssertEqual(upright.frameHeight, 475)
        let p = upright.normalizedPoint!
        let expected = DisplayOrientation.point((3445.0 / 9504, 4778.0 / 6336), exif: 8)
        XCTAssertEqual(p.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(p.y, expected.y, accuracy: 1e-9)
    }

    func testFocusLocationOrientations1_3_6() {
        let f = FocusLocation(imageWidth: 100, imageHeight: 50, x: 20, y: 10)
        XCTAssertEqual(f.displayOriented(exif: 1), f)
        XCTAssertEqual(f.displayOriented(exif: nil), f)
        let r3 = f.displayOriented(exif: 3)
        XCTAssertEqual([r3.x, r3.y], [80, 40])
        let r6 = f.displayOriented(exif: 6)
        XCTAssertEqual([r6.imageWidth, r6.imageHeight, r6.x, r6.y], [50, 100, 40, 20])
    }
}
