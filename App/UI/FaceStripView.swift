import SwiftUI

import VampireIndex

/// Quality-ranked face crops for the current frame. Crops are cut from the
/// cheap preview using the normalized rects persisted by the indexer — no
/// Vision on the UI path (hard constraint 4).
struct FaceStripView: View {
    @Environment(AppModel.self) private var model
    let assetID: String?
    /// Horizontal above the photo in portrait; vertical in the landscape rail.
    var axis: Axis = .horizontal
    /// Crop edge in points; bigger on wide screens (iPhone Duo side panel).
    var cropSize: CGFloat = 44

    @State private var crops: [FaceCrop] = []

    struct FaceCrop: Identifiable {
        let id: Int64
        let image: UIImage
        let quality: Double?
        /// True when this face was caught mid-blink — ringed red in the strip.
        let isBlinking: Bool
        /// True when this face intersects the AF box: the face the camera
        /// focused on. Always first in the strip, ringed green.
        let isAFSubject: Bool
    }

    var body: some View {
        Group {
            if crops.isEmpty {
                Color.clear
            } else if axis == .horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(crops) { crop in
                            cropView(crop)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(crops) { crop in
                            cropView(crop)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // Camera sessions: re-crop when the full preview replaces the
        // thumbnail stand-in (imageRevision bumps as frames land).
        .task(id: "\(assetID ?? "")#\(model.isCameraSession ? model.imageRevision : 0)") {
            crops = await loadCrops()
        }
    }

    private func cropView(_ crop: FaceCrop) -> some View {
        VStack(spacing: 2) {
            Image(uiImage: crop.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cropSize, height: cropSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    // Blink warning outranks the AF-subject ring.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            crop.isBlinking ? .red : .green,
                            lineWidth: crop.isBlinking ? 2 : (crop.isAFSubject ? 1.5 : 0)
                        )
                )
            if let quality = crop.quality {
                QualityDots(quality: quality)
            }
        }
    }

    private func loadCrops() async -> [FaceCrop] {
        guard let assetID,
              let store = model.store,
              let faces = try? store.faces(forAsset: assetID), !faces.isEmpty,
              let item = model.items.first(where: { $0.id == assetID })
        else { return [] }

        // The face under the AF box — the one the camera focused on — leads
        // the strip; the rest follow by capture quality (store order).
        let afRect = afRect(forAsset: assetID)
        func intersectsAF(_ face: FaceRecord) -> Bool {
            guard let afRect else { return false }
            return afRect.intersects(CGRect(x: face.x, y: face.y, width: face.width, height: face.height))
        }
        let ranked = faces.sorted { a, b in
            let aAF = intersectsAF(a), bAF = intersectsAF(b)
            if aAF != bAF { return aAF }
            return (a.captureQuality ?? 0) > (b.captureQuality ?? 0)
        }

        // One small preview request, then CG crops — cheap and synchronous-safe.
        // Face rects are upright-normalized; Photos hands portrait previews
        // over as a sideways bitmap + orientation, so draw upright first or
        // the crops come from the wrong place.
        guard let image = await model.imageProvider.preview(for: item, targetSize: CGSize(width: 640, height: 640)),
              let cgImage = Self.upright(image).cgImage else { return [] }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        return ranked.compactMap { face in
            let rect = CGRect(
                x: face.x * width,
                y: face.y * height,
                width: face.width * width,
                height: face.height * height
            ).insetBy(dx: -0.1 * face.width * width, dy: -0.1 * face.height * height)
            guard let crop = cgImage.cropping(to: rect.integral) else { return nil }
            return FaceCrop(
                id: face.id ?? Int64(crops.count),
                image: UIImage(cgImage: crop),
                quality: face.captureQuality,
                isBlinking: (face.eyesOpen ?? 1) < 0.18,
                isAFSubject: intersectsAF(face)
            )
        }
    }

    /// The AF box in normalized top-left coordinates: the camera's frame
    /// when it wrote one, otherwise a small box around the focus point.
    private func afRect(forAsset assetID: String) -> CGRect? {
        guard let focus = model.index[assetID]?.focusLocation else { return nil }
        if let frame = focus.normalizedFrame {
            return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        guard let point = focus.normalizedPoint else { return nil }
        return CGRect(x: point.x - 0.025, y: point.y - 0.025, width: 0.05, height: 0.05)
    }

    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }
}

/// Tiny 0–5 dot meter for face capture quality.
struct QualityDots: View {
    let quality: Double

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0 ..< 5, id: \.self) { i in
                Circle()
                    .fill(Double(i) / 5.0 < quality ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 3.5, height: 3.5)
            }
        }
    }
}
