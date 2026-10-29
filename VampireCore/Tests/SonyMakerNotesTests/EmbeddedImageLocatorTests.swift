import XCTest
@testable import SonyMakerNotes

final class EmbeddedImageLocatorTests: XCTestCase {

    /// Validated against fixtures/DSC04319.ARW via exiftool:
    ///   PreviewImageStart 192674 / Length 352435  (IFD0, 1616×1080)
    ///   ThumbnailOffset   43872  / Length 11489    (IFD1)
    ///   JpgFromRawStart   548864 / Length 6840442  (IFD2, full)
    func testLocatesThreeTierLadderInRealARW() throws {
        let url = Self.fixturesURL.appendingPathComponent("DSC04319.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "fixture DSC04319.ARW not present")
        // Only the head is needed — the offset tags live in the IFD chain,
        // not the pixel data. 256KB easily covers all three IFDs here.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 256 * 1024) ?? Data()

        let images = try EmbeddedImageLocator.locate(in: head)
        XCTAssertEqual(images.thumbnail, EmbeddedImageRange(offset: 43872, length: 11489))
        XCTAssertEqual(images.preview, EmbeddedImageRange(offset: 192674, length: 352435))
        XCTAssertEqual(images.full, EmbeddedImageRange(offset: 548864, length: 6840442))
        XCTAssertEqual(images.bestCullingPreview, images.preview)
    }

    /// The located preview range must actually be a valid JPEG (SOI..EOI) —
    /// proves offset/length are right for a real partial transfer.
    func testPreviewRangeIsAValidJPEG() throws {
        let url = Self.fixturesURL.appendingPathComponent("DSC04319.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "fixture DSC04319.ARW not present")
        let full = try Data(contentsOf: url)
        let images = try EmbeddedImageLocator.locate(in: full.prefix(256 * 1024))
        let p = try XCTUnwrap(images.preview)
        let jpeg = full.subdata(in: p.offset ..< p.end)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "preview starts with JPEG SOI")
        XCTAssertEqual(Array(jpeg.suffix(2)), [0xFF, 0xD9], "preview ends with JPEG EOI")
    }

    func testTruncatedHeadAsksForMore() {
        // A TIFF header whose IFD0 points past the provided bytes.
        var data = Data([0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x04, 0x00]) // IFD0 at 256KB
        XCTAssertThrowsError(try EmbeddedImageLocator.locate(in: data)) { error in
            guard case ARWParseError.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    static var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // strip EmbeddedImageLocatorTests.swift
            .deletingLastPathComponent() // SonyMakerNotesTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // VampireCore/ → repo root
            .appendingPathComponent("fixtures")
    }
}
