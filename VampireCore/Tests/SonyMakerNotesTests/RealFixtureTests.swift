import XCTest
@testable import SonyMakerNotes

/// Runs the parser against real A7RV ARW files in `fixtures/` at the repo root.
///
/// For each `<name>.ARW`, an optional `<name>.expected.json` holds ground truth
/// captured from `exiftool -a -G1 -v3 <name>.ARW`:
///
///     { "focusLocation": [9504, 6336, 4752, 3168], "model": "ILCE-7RM5" }
///
/// Per CLAUDE.md: when adding a layout assumption, add the fixture + the
/// exiftool dump here. With no fixtures present these tests skip — synthetic
/// coverage lives in ARWHeadParserTests.
final class RealFixtureTests: XCTestCase {
    struct Expected: Decodable {
        var focusLocation: [Int]?
        var focusFrameSize: [Int]?
        var model: String?
        var make: String?
        /// Raw FacePositions pixels (x1 y1 x2 y2 per face), exiftool values.
        var facePositions: [UInt32]?
    }

    static let fixtureExtensions: Set<String> = ["arw", "raf", "jpg", "jpeg"]

    static var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // strip RealFixtureTests.swift
            .deletingLastPathComponent() // strip SonyMakerNotesTests/
            .deletingLastPathComponent() // strip Tests/
            .deletingLastPathComponent() // strip VampireCore/ → repo root
            .appendingPathComponent("fixtures")
    }

    func testRealFixtures() throws {
        let fixtures = (try? FileManager.default.contentsOfDirectory(
            at: Self.fixturesURL, includingPropertiesForKeys: nil
        ))?.filter { Self.fixtureExtensions.contains($0.pathExtension.lowercased()) } ?? []

        try XCTSkipIf(fixtures.isEmpty, "no camera fixtures in fixtures/ — add real files to enable")

        for url in fixtures.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            // Read only the head, exactly as the app would.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: ARWHeadParser.recommendedHeadLength) ?? Data()

            let metadata: ARWMetadata
            do {
                metadata = try CameraHeadParser.parse(head: head)
            } catch {
                XCTFail("\(name): parse failed: \(error)")
                continue
            }
            XCTAssertNotNil(metadata.make, name)

            let expectedURL = url.deletingPathExtension().appendingPathExtension("expected.json")
            guard let expectedData = try? Data(contentsOf: expectedURL) else {
                // No ground truth yet: log what we found so it can be checked
                // against exiftool and captured.
                print("[\(name)] model=\(metadata.model ?? "?") focus=\(String(describing: metadata.focusLocation))")
                continue
            }
            let expected = try JSONDecoder().decode(Expected.self, from: expectedData)
            if let make = expected.make {
                XCTAssertEqual(metadata.make, make, name)
            }
            if let model = expected.model {
                XCTAssertEqual(metadata.model, model, name)
            }
            if let focus = expected.focusLocation {
                let parsed = try XCTUnwrap(metadata.focusLocation, "\(name): FocusLocation missing")
                XCTAssertEqual([parsed.imageWidth, parsed.imageHeight, parsed.x, parsed.y], focus, name)
            }
            if let frame = expected.focusFrameSize {
                let parsed = try XCTUnwrap(metadata.focusLocation, "\(name): FocusLocation missing")
                XCTAssertEqual([parsed.frameWidth, parsed.frameHeight], frame.map(Optional.init), name)
            }
            if let positions = expected.facePositions {
                XCTAssertEqual(metadata.makerNote?.rawTagValues[0x4103], positions, name)
                XCTAssertEqual(metadata.cameraFaces.count, positions.count / 4, name)
            }
        }
    }

    /// The app never reads a fixture in one go — it streams chunks and cancels.
    /// Replay that exact flow against the real file: HeadParseSession must
    /// finish well inside the head, on a chunk boundary mid-file.
    func testRealFixtureParsesViaStreamingSession() throws {
        let fixtures = (try? FileManager.default.contentsOfDirectory(
            at: Self.fixturesURL, includingPropertiesForKeys: nil
        ))?.filter { Self.fixtureExtensions.contains($0.pathExtension.lowercased()) } ?? []
        try XCTSkipIf(fixtures.isEmpty, "no camera fixtures")

        let chunkSize = 64 * 1024 // PHAssetResourceManager delivers chunks of this order
        for url in fixtures {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let session = HeadParseSession()
            var outcome: HeadParseSession.Step = .needMoreData
            while case .needMoreData = outcome {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return XCTFail("\(url.lastPathComponent): file ended before parse settled")
                }
                outcome = session.ingest(chunk)
            }

            guard case .done(let metadata) = outcome else {
                return XCTFail("\(url.lastPathComponent): streaming parse failed: \(outcome)")
            }
            XCTAssertNotNil(metadata.makerNote, url.lastPathComponent)
            // The whole point of the streamed read: we stopped near the head,
            // nowhere near the full 60-130MB file.
            XCTAssertLessThanOrEqual(
                session.bytesIngested,
                ARWHeadParser.recommendedHeadLength,
                "\(url.lastPathComponent): read \(session.bytesIngested) bytes"
            )
        }
    }
}
