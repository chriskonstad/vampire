import Foundation
import UIKit

import SonyMakerNotes
import VampireIndex

extension CameraPhoto {
    /// Index/journal key for a shot on the card: filename + millisecond
    /// capture time. Survives reconnects and moving the card between slots
    /// (Sony content IDs and slots don't), and filenames reused after a
    /// format/rollover still differ by capture time.
    var indexID: String { "camera:\(filename)@\(createdUTCms)" }
}

/// On-disk cache of each camera shot's upright cull preview and grid
/// thumbnail, in Library/Caches: it survives relaunches and disconnects, so
/// culling a card you've seen before never re-downloads pixels. Files are
/// keyed by the shot's stable index ID; shots that leave the card have their
/// files removed, and iOS may purge Caches under storage pressure (we just
/// re-fetch).
final class CameraFrameCache: Sendable {
    static let shared = CameraFrameCache()

    let directory: URL

    private init() {
        directory = URL.cachesDirectory.appendingPathComponent("camera-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The old per-launch cache lived in tmp; drop it.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-cache", isDirectory: true))
    }

    /// "camera:DSC05508.ARW@1793247396115" -> "DSC05508.ARW-1793247396115"
    private func fileStem(forIndexID id: String) -> String {
        String(id.dropFirst("camera:".count)).replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    func previewURL(forIndexID id: String) -> URL {
        directory.appendingPathComponent(fileStem(forIndexID: id) + ".jpg")
    }

    func thumbnailURL(forIndexID id: String) -> URL {
        directory.appendingPathComponent(fileStem(forIndexID: id) + ".thumb.jpg")
    }

    func previewURL(for photo: CameraPhoto) -> URL { previewURL(forIndexID: photo.indexID) }

    func hasPreview(forIndexID id: String) -> Bool {
        FileManager.default.fileExists(atPath: previewURL(forIndexID: id).path)
    }

    func removeFiles(forIndexID id: String) {
        try? FileManager.default.removeItem(at: previewURL(forIndexID: id))
        try? FileManager.default.removeItem(at: thumbnailURL(forIndexID: id))
    }

    struct Processed: Sendable {
        let previewURL: URL
        /// Nil when `analyze` was false (already indexed in an earlier run).
        let record: AssetIndexRecord?
        let faces: [FaceRecord]
    }

    /// Bakes the screennail upright to disk and — unless already indexed —
    /// runs the same extraction as the library indexer: Vision on the
    /// 1616px preview (faces/eyes, quality, feature print, aesthetics,
    /// horizon, saliency, exposure) plus EXIF/MakerNotes from the RAW head
    /// (model, orientation, AF point + frame). Off the main actor.
    func process(_ photo: CameraPhoto, screennail: Data, metadata: ARWMetadata?,
                 analyze: Bool) throws -> Processed {
        guard let decoded = UIImage(data: screennail) else { throw CocoaError(.fileReadCorruptFile) }
        let upright = UIGraphicsImageRenderer(size: decoded.size, format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { _ in decoded.draw(at: .zero) }
        let url = previewURL(for: photo)
        try upright.jpegData(compressionQuality: 0.9)?.write(to: url)
        guard analyze else { return Processed(previewURL: url, record: nil, faces: []) }

        // AF lives in sensor space: map by the RAW's orientation (the
        // preview's own EXIF agrees on the A7RV and is the fallback).
        let orientation = metadata?.orientation ?? exif(decoded.imageOrientation)
        let rotated = orientation == 6 || orientation == 8

        let analysis = upright.cgImage.map { VisionAnalyzer.analyze(cgImage: $0, assetID: photo.indexID) }
        let faces = analysis?.faces ?? []
        var record = AssetIndexRecord(
            assetID: photo.indexID,
            // Sony's card listing has millisecond capture times — EXIF only
            // has seconds, too coarse for <1s burst chains.
            creationDate: photo.capturedAt,
            pixelWidth: rotated ? photo.pixelHeight : photo.pixelWidth,
            pixelHeight: rotated ? photo.pixelWidth : photo.pixelHeight,
            isRAW: photo.isRAW,
            indexedAt: Date(),
            cameraModel: metadata?.model,
            focusLocation: metadata?.focusLocation?.displayOriented(exif: orientation),
            bestFaceQuality: analysis?.bestFaceQuality,
            faceCount: faces.count
        )
        record.featurePrint = analysis?.featurePrint
        record.indexVersion = IndexStore.currentIndexVersion
        record.aestheticScore = analysis?.aestheticScore
        record.isUtility = analysis?.isUtility
        record.horizonDegrees = analysis?.horizonDegrees
        record.salientRect = analysis?.salientRect
        record.clippedHighlights = analysis?.clippedHighlights
        record.crushedShadows = analysis?.crushedShadows
        record.meanLuma = analysis?.meanLuma
        record.closedEyesCount = analysis?.closedEyesCount
        return Processed(previewURL: url, record: record, faces: faces)
    }

    private func exif(_ orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .down: 3
        case .right: 6
        case .left: 8
        default: 1
        }
    }
}
