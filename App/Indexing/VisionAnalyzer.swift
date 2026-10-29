import Vision
import CoreGraphics

import VampireIndex
import SonyMakerNotes

/// Signal extraction for the indexing pass, all on ~1024px previews — never
/// full res. One pass per asset, persisted; the UI only ever reads the index
/// (hard constraint 4: if UI code is calling this, that's a bug).
///
/// Every request runs independently: one model failing (e.g. anything
/// neural on the simulator) must not take down the rest. A nil signal means
/// "not computed / not applicable" and the HUD simply omits it.
struct VisionAnalysis {
    var faces: [FaceRecord]
    var bestFaceQuality: Double?
    var featurePrint: [Float]?

    // HUD signals
    var aestheticScore: Double?     // -1...1 overall
    var isUtility: Bool?            // screenshots/receipts/docs
    var horizonDegrees: Double?     // signed tilt; nil = no horizon found
    var salientRect: SonyMakerNotes.NormalizedRect? // attention box, top-left normalized
    var clippedHighlights: Double?  // fraction of blown pixels
    var crushedShadows: Double?     // fraction of crushed pixels
    var meanLuma: Double?

    var closedEyesCount: Int {
        faces.filter { ($0.eyesOpen ?? 1) < VisionAnalyzer.blinkThreshold }.count
    }
}

enum VisionAnalyzer {
    /// Eye-openness below this reads as a blink.
    static let blinkThreshold = 0.18

    static func analyze(cgImage: CGImage, assetID: String, orientation: CGImagePropertyOrientation = .up) -> VisionAnalysis {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)

        let faceRequest = VNDetectFaceRectanglesRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let printRequest = VNGenerateImageFeaturePrintRequest()
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        let horizonRequest = VNDetectHorizonRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        var failures: [String] = []
        func perform(_ request: VNRequest, _ name: String) {
            do { try handler.perform([request]) } catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        perform(qualityRequest, "quality")
        perform(faceRequest, "faces")
        perform(landmarksRequest, "landmarks")
        perform(printRequest, "print")
        perform(aestheticsRequest, "aesthetics")
        perform(horizonRequest, "horizon")
        perform(saliencyRequest, "saliency")
        if !failures.isEmpty {
            log.error("Vision partial failure for \(assetID): \(failures.joined(separator: " | "))")
        }

        // Union of the rects + quality requests (quality only processes a few
        // prominent faces; preferring it alone dropped crowds), then eye
        // openness attached from the landmarks request — all matched by IoU
        // in Vision's bottom-left space before the flip.
        var merged: [(box: CGRect, quality: Double?, eyesOpen: Double?)] =
            (faceRequest.results ?? []).map { ($0.boundingBox, nil, nil) }
        for observation in qualityRequest.results ?? [] {
            let quality = observation.faceCaptureQuality.map(Double.init)
            let box = observation.boundingBox
            if let index = bestMatch(for: box, in: merged) {
                merged[index].quality = quality
            } else {
                merged.append((box, quality, nil))
            }
        }
        for observation in landmarksRequest.results ?? [] {
            let openness = eyeOpenness(of: observation)
            if let index = bestMatch(for: observation.boundingBox, in: merged) {
                merged[index].eyesOpen = openness
            } else {
                // The landmarks detector found a face the others missed —
                // three detectors' union beats any single one's recall.
                merged.append((observation.boundingBox, nil, openness))
            }
        }

        let faces = merged.map { face -> FaceRecord in
            // Vision rects are normalized with a bottom-left origin; the UI
            // and FaceRecord use top-left.
            FaceRecord(
                assetID: assetID,
                x: face.box.origin.x,
                y: 1 - face.box.origin.y - face.box.height,
                width: face.box.width,
                height: face.box.height,
                captureQuality: face.quality,
                eyesOpen: face.eyesOpen
            )
        }

        var featurePrint: [Float]?
        if let observation = printRequest.results?.first as? VNFeaturePrintObservation {
            featurePrint = floatVector(from: observation)
        }

        let aesthetics = aestheticsRequest.results?.first
        let horizon = horizonRequest.results?.first
        let exposure = exposureStats(of: cgImage)

        var salientRect: SonyMakerNotes.NormalizedRect?
        if let salient = (saliencyRequest.results?.first as? VNSaliencyImageObservation)?.salientObjects,
           !salient.isEmpty {
            let union = salient.dropFirst().reduce(salient[0].boundingBox) { $0.union($1.boundingBox) }
            salientRect = SonyMakerNotes.NormalizedRect(
                x: union.origin.x,
                y: 1 - union.origin.y - union.height,
                width: union.width,
                height: union.height
            )
        }

        return VisionAnalysis(
            faces: faces,
            bestFaceQuality: faces.compactMap(\.captureQuality).max(),
            featurePrint: featurePrint,
            aestheticScore: aesthetics.map { Double($0.overallScore) },
            isUtility: aesthetics?.isUtility,
            horizonDegrees: horizon.map { Double($0.angle) * 180 / .pi },
            salientRect: salientRect,
            clippedHighlights: exposure?.clipped,
            crushedShadows: exposure?.crushed,
            meanLuma: exposure?.mean
        )
    }

    // MARK: - Eyes

    /// Eye-openness 0...1 from the eye landmark outlines: aspect ratio of
    /// each eye's point cloud (height/width), min of the two eyes, mapped so
    /// ~0.12 (shut) → 0 and ~0.30 (wide open) → 1.
    private static func eyeOpenness(of face: VNFaceObservation) -> Double? {
        guard let landmarks = face.landmarks else { return nil }
        let ratios = [landmarks.leftEye, landmarks.rightEye]
            .compactMap { $0 }
            .compactMap { aspectRatio(of: $0) }
        guard !ratios.isEmpty else { return nil }
        let ear = ratios.min()!
        return min(1, max(0, (ear - 0.12) / 0.18))
    }

    private static func aspectRatio(of region: VNFaceLandmarkRegion2D) -> Double? {
        let points = region.normalizedPoints
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = Double(xs.max()! - xs.min()!)
        let height = Double(ys.max()! - ys.min()!)
        guard width > 0 else { return nil }
        return height / width
    }

    // MARK: - Exposure (no neural net: works everywhere, simulator included)

    /// Luma histogram over a 64×64 resample of the preview: fraction of blown
    /// highlights, crushed shadows, and mean luminance.
    static func exposureStats(of image: CGImage) -> (clipped: Double, crushed: Double, mean: Double)? {
        let side = 64
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var clipped = 0, crushed = 0
        var total = 0.0
        let count = side * side
        for i in 0 ..< count {
            let r = Double(pixels[i * 4])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luma >= 250 { clipped += 1 }
            if luma <= 6 { crushed += 1 }
            total += luma
        }
        return (
            clipped: Double(clipped) / Double(count),
            crushed: Double(crushed) / Double(count),
            mean: total / Double(count) / 255.0
        )
    }

    // MARK: - Matching

    private static func bestMatch(
        for box: CGRect,
        in faces: [(box: CGRect, quality: Double?, eyesOpen: Double?)]
    ) -> Int? {
        guard let index = faces.indices.max(by: {
            overlapRatio(faces[$0].box, box) < overlapRatio(faces[$1].box, box)
        }), overlapRatio(faces[index].box, box) > 0.3 else { return nil }
        return index
    }

    /// Intersection-over-union of two normalized rects.
    static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let unionArea = a.width * a.height + b.width * b.height
            - intersection.width * intersection.height
        guard unionArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / unionArea
    }

    /// Extracts the raw vector so distances can be computed offline (pure
    /// logic, persisted in the index) instead of requiring live observations.
    static func floatVector(from observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float else {
            log.error("unexpected feature print element type")
            return nil
        }
        let count = observation.elementCount
        return observation.data.withUnsafeBytes { raw -> [Float]? in
            guard raw.count >= count * MemoryLayout<Float>.stride else { return nil }
            return Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
