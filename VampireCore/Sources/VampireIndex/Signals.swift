import CoreGraphics

/// Signal math that the index stores and the UI reads — pure, no Vision types.
/// The analyzer (App) assembles the observations; this package holds the
/// arithmetic so it can be pinned down with synthetic inputs.
public enum SignalAnalysis {
    /// Eye-openness below this reads as a blink.
    public static let blinkThreshold: Double = 0.18

    /// Count of faces whose eye-openness reads as a blink.
    /// A nil openness (not computed / not applicable) counts as open.
    public static func closedEyes(faces: [FaceRecord], threshold: Double = blinkThreshold) -> Int {
        faces.filter { ($0.eyesOpen ?? 1) < threshold }.count
    }

    /// Intersection-over-union of two normalized rects.
    public static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let unionArea =
            a.width * a.height + b.width * b.height
            - intersection.width * intersection.height
        guard unionArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / unionArea
    }

    /// Luma histogram over a 64×64 resample of the image: fraction of blown
    /// highlights, crushed shadows, and mean luminance. Pure CoreGraphics —
    /// works in the simulator and headless CI.
    public static func exposureStats(of image: CGImage) -> (clipped: Double, crushed: Double, mean: Double)? {
        let side = 64
        guard
            let context = CGContext(
                data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var clipped = 0
        var crushed = 0
        var total = 0.0
        let count = side * side
        for i in 0..<count {
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
}
