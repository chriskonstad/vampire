import Photos
import UIKit

import VampireIndex
import SonyMakerNotes

enum IndexUpdate: Sendable {
    case progress(done: Int, total: Int)
    case indexed(AssetIndexRecord, faces: [FaceRecord])
}

/// The one-time background indexing pass. Everything expensive happens here,
/// once, and is persisted: head-of-file EXIF/MakerNotes, Vision faces +
/// quality, feature prints. Resumable — already-indexed assets are skipped.
final class Indexer: @unchecked Sendable {
    private let store: IndexStore
    private let imageManager: PHImageManager
    private var cancelled = false
    private let lock = NSLock()

    /// Sized for I/O-bound work without flooding photolibraryd.
    private let maxConcurrent = 4
    /// Vision target size; quality/print results are stable at ~1024px.
    private static let analysisSize = CGSize(width: 1024, height: 1024)

    init(store: IndexStore, imageManager: PHImageManager) {
        self.store = store
        self.imageManager = imageManager
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func run(assets: [PHAsset], onUpdate: @escaping @Sendable (IndexUpdate) -> Void) async {
        let already = (try? store.indexedAssetIDs()) ?? []
        let pending = assets.filter { !already.contains($0.localIdentifier) }
        let total = assets.count
        var done = total - pending.count
        onUpdate(.progress(done: done, total: total))

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                while inFlight < maxConcurrent, !isCancelled, let asset = iterator.next() {
                    inFlight += 1
                    group.addTask { [self] in
                        await indexOne(asset, onUpdate: onUpdate)
                    }
                }
            }

            enqueueNext()
            while await group.next() != nil {
                inFlight -= 1
                done += 1
                onUpdate(.progress(done: done, total: total))
                enqueueNext()
            }
        }
    }

    private func indexOne(_ asset: PHAsset, onUpdate: @escaping @Sendable (IndexUpdate) -> Void) async {
        let assetID = asset.localIdentifier
        let isRAW = AssetHeadReader.rawResource(for: asset) != nil

        // 1. Head-of-file metadata: AF point, camera model, camera faces.
        //    RAW heads and EXIF JPEGs both parse (Sony ARW, Fuji RAF/JPEG).
        let headMetadata = await AssetHeadReader.readMetadata(for: asset)

        // 2. Vision on the embedded ~1024px preview — no RAW decode. The
        //    UIImage's orientation MUST travel with the CGImage: portrait
        //    shots store their bitmap sideways, and face detection misses
        //    most 90°-rotated faces if Vision is told the image is upright.
        var analysis: VisionAnalysis?
        if let image = await requestPreview(for: asset), let cgImage = image.cgImage {
            analysis = VisionAnalyzer.analyze(
                cgImage: cgImage,
                assetID: assetID,
                orientation: CGImagePropertyOrientation(image.imageOrientation)
            )
        }

        guard !isCancelled else { return }

        // 3. Faces: Vision's (with quality) unioned with the camera's own
        //    face frames from MakerNotes (gold for who-was-detected, no
        //    quality score). Overlapping rects keep the Vision entry.
        var faces = analysis?.faces ?? []
        // MakerNotes geometry is in sensor space; everything the UI draws
        // on (and Vision's faces) is upright. Map through the orientation —
        // unmapped, portrait AF boxes landed in the wrong place.
        let orientation = headMetadata?.orientation
        for sensorRect in headMetadata?.cameraFaces ?? [] {
            let rect = DisplayOrientation.rect(sensorRect, exif: orientation)
            let cameraBox = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            let overlapsExisting = faces.contains { face in
                VisionAnalyzer.overlapRatio(
                    CGRect(x: face.x, y: face.y, width: face.width, height: face.height),
                    cameraBox
                ) > 0.3
            }
            if !overlapsExisting {
                faces.append(FaceRecord(
                    assetID: assetID,
                    x: rect.x, y: rect.y, width: rect.width, height: rect.height,
                    captureQuality: nil
                ))
            }
        }

        // 4. Persist. The record carries indexedAt + indexVersion so the
        //    pass can resume and re-runs when the pipeline learns new signals.
        var record = AssetIndexRecord(
            assetID: assetID,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isRAW: isRAW,
            indexedAt: Date(),
            cameraModel: headMetadata?.model,
            focusLocation: headMetadata?.focusLocation?.displayOriented(exif: orientation),
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

        do {
            try store.upsert(record)
            try store.replaceFaces(faces, forAsset: assetID)
            onUpdate(.indexed(record, faces: faces))
        } catch {
            log.error("failed to persist index for \(assetID): \(error.localizedDescription)")
        }
    }

    /// Embedded preview at analysis size. `.opportunistic` would deliver twice;
    /// `.highQualityFormat` waits for the good one — fine off the UI path.
    /// Returns the UIImage so its orientation survives to the Vision pass.
    private func requestPreview(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            imageManager.requestImage(
                for: asset,
                targetSize: Self.analysisSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded else { return }
                guard resumed.tryFinish() else { return }
                continuation.resume(returning: image)
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }
}
