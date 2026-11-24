import XCTest
@testable import PTP

private func photo(
    filename: String, createdUTCms: UInt64, slot: UInt32 = 1, contentID: UInt32 = 0x20001,
    isRAW: Bool = true, pixelWidth: Int = 6000, pixelHeight: Int = 4000
) -> CameraPhoto {
    CameraPhoto(
        slot: slot, contentID: contentID, fileID: 1, filename: filename,
        sizeBytes: 60_000_000, isRAW: isRAW, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
        createdUTCms: createdUTCms, rating: 0, isProtected: false)
}

/// The camera card identity + merge logic, extracted from the app so the
/// cache keys and card-listing diff are pinned down without a camera.
final class CameraShotTests: XCTestCase {

    // MARK: - indexID

    func testIndexIDFormat() {
        let p = photo(filename: "DSC05508.ARW", createdUTCms: 1_793_247_396_115)
        XCTAssertEqual(p.indexID, "camera:DSC05508.ARW@1793247396115")
    }

    func testIndexIDSurvivesSameFilenameDifferentTimestamp() {
        // A format/rollover reuse of the filename must not collide.
        let earlier = photo(filename: "DSC00001.ARW", createdUTCms: 1_000)
        let later = photo(filename: "DSC00001.ARW", createdUTCms: 2_000)
        XCTAssertNotEqual(earlier.indexID, later.indexID)
    }

    func testCapturedAtDerivedFromMilliseconds() {
        let p = photo(filename: "DSC00001.ARW", createdUTCms: 1_700_000_000_000)
        XCTAssertEqual(p.capturedAt.timeIntervalSince1970, 1_700_000_000.0, accuracy: 0.001)
    }

    // MARK: - fileStem / inventory round-trip

    func testFileStemEncoding() {
        XCTAssertEqual(
            CameraFrameIdentity.fileStem(forIndexID: "camera:DSC05508.ARW@1793247396115"),
            "DSC05508.ARW-1793247396115")
    }

    func testFileStemSanitizesPathSeparators() {
        XCTAssertEqual(
            CameraFrameIdentity.fileStem(forIndexID: "camera:a/b/c.ARW@123"),
            "a_b_c.ARW-123")
    }

    func testInventoryParseRoundTrip() {
        for name in ["DSC05508.ARW-1793247396115.jpg", "DSC05508.ARW-1793247396115.thumb.jpg"] {
            let parsed = CameraFrameIdentity.indexID(forFileName: name)
            let expectedID = "camera:DSC05508.ARW@1793247396115"
            XCTAssertEqual(parsed?.id, expectedID)
            XCTAssertEqual(parsed?.isThumbnail, name.hasSuffix(".thumb.jpg"))
        }
    }

    func testInventoryIgnoresGridAndUnknownNames() {
        XCTAssertNil(CameraFrameIdentity.indexID(forFileName: "DSC05508.ARW-1793247396115.grid.jpg"))
        XCTAssertNil(CameraFrameIdentity.indexID(forFileName: "random.txt"))
        XCTAssertNil(CameraFrameIdentity.indexID(forFileName: "no-dash.jpg"))
        XCTAssertNil(CameraFrameIdentity.indexID(forFileName: "DSC05508.ARW-notanumber.jpg"))
    }

    func testInventoryParsesHyphenatedFilenames() {
        // Filenames may contain "-": the LAST "-" is the separator before
        // the timestamp.
        let parsed = CameraFrameIdentity.indexID(forFileName: "DSC-foo_bar.ARW-1793247396115.jpg")
        XCTAssertEqual(parsed?.id, "camera:DSC-foo_bar.ARW@1793247396115")
    }

    func testFileStemAndIndexIDAreInverse() {
        let id = "camera:DSC05508.ARW@1793247396115"
        let stem = CameraFrameIdentity.fileStem(forIndexID: id)
        XCTAssertEqual(CameraFrameIdentity.indexID(forFileName: stem + ".jpg")?.id, id)
    }

    // MARK: - CardListing.merge

    func testMergeSortsByCaptureTime() {
        let b = photo(filename: "B.ARW", createdUTCms: 200)
        let a = photo(filename: "A.ARW", createdUTCms: 100)
        let result = CardListing.merge(known: [], list: [b, a])
        XCTAssertEqual(result.photos.map(\.filename), ["A.ARW", "B.ARW"])
    }

    func testMergeFreshAndGone() {
        let old = photo(filename: "old.ARW", createdUTCms: 100)
        let gone = photo(filename: "gone.ARW", createdUTCms: 200)
        let fresh = photo(filename: "new.ARW", createdUTCms: 300)
        let result = CardListing.merge(known: [old, gone], list: [old, fresh])
        XCTAssertEqual(result.fresh.map(\.filename), ["new.ARW"])
        XCTAssertEqual(result.gone, [gone.indexID])
        XCTAssertEqual(result.photos.map(\.filename), ["old.ARW", "new.ARW"])
    }

    func testMergeEmptyListKeepsNothing() {
        let old = photo(filename: "old.ARW", createdUTCms: 100)
        let result = CardListing.merge(known: [old], list: [])
        XCTAssertTrue(result.photos.isEmpty)
        XCTAssertTrue(result.fresh.isEmpty)
        XCTAssertEqual(result.gone, [old.indexID])
    }

    func testMergeEmptyKnownEverythingIsFresh() {
        let a = photo(filename: "A.ARW", createdUTCms: 100)
        let b = photo(filename: "B.ARW", createdUTCms: 200)
        let result = CardListing.merge(known: [], list: [a, b])
        XCTAssertEqual(result.fresh.map(\.filename), ["A.ARW", "B.ARW"])
        XCTAssertTrue(result.gone.isEmpty)
    }
}
