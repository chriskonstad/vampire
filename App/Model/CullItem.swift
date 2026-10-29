import Photos
import UIKit

/// One photo in a culling session, whatever its source. The culling UI
/// (grid, pager, face strip, HUD) works on these, so a camera card culls
/// with exactly the same screens as the Photos library.
///
/// `id` is the index/journal join key: `PHAsset.localIdentifier` for library
/// photos (hard constraint 5), `camera:…` for shots still on a camera card.
struct CullItem: Identifiable, Hashable {
    let id: String
    let creationDate: Date?
    /// Set for library photos; nil for camera-card shots.
    let asset: PHAsset?

    init(asset: PHAsset) {
        id = asset.localIdentifier
        creationDate = asset.creationDate
        self.asset = asset
    }

    init(cameraID: String, creationDate: Date?) {
        id = cameraID
        self.creationDate = creationDate
        asset = nil
    }
}

/// Where the culling UI gets pixels. Library sessions read Photos' cheap
/// embedded previews; camera sessions read the session cache filled over
/// Wi-Fi. Neither ever decodes a full RAW (hard constraint 2).
@MainActor
protocol CullImageProvider: AnyObject {
    /// Grid-size image. May deliver twice (fast degraded, then final).
    func requestThumbnail(for item: CullItem, targetSize: CGSize, _ handler: @escaping (UIImage?) -> Void)

    /// Screen-size image for the pager. `isFinal` false = a degraded
    /// placeholder that a better image will follow. Returns a cancel action.
    @discardableResult
    func requestPreview(for item: CullItem, targetSize: CGSize,
                        _ handler: @escaping (_ image: UIImage?, _ isFinal: Bool) -> Void) -> (() -> Void)?

    func startCaching(_ items: [CullItem], targetSize: CGSize)
    func stopCaching(_ items: [CullItem], targetSize: CGSize)
    func stopCachingAll()

    /// False while only a stand-in (e.g. a camera thumbnail) is available;
    /// the loader re-requests such items when `AppModel.imageRevision` bumps.
    func hasFullPreview(for item: CullItem) -> Bool
}

extension CullImageProvider {
    /// One upright image at `targetSize`, for off-screen work (face crops).
    func preview(for item: CullItem, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce()
            requestPreview(for: item, targetSize: targetSize) { image, isFinal in
                guard isFinal, once.tryFinish() else { return }
                cont.resume(returning: image)
            }
        }
    }
}

/// Photos library images via the shared caching manager.
@MainActor
final class LibraryImageProvider: CullImageProvider {
    let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    func requestThumbnail(for item: CullItem, targetSize: CGSize, _ handler: @escaping (UIImage?) -> Void) {
        guard let asset = item.asset else { return handler(nil) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic // degraded instantly, refined later
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill,
                                  options: options) { image, _ in handler(image) }
    }

    func requestPreview(for item: CullItem, targetSize: CGSize,
                        _ handler: @escaping (UIImage?, Bool) -> Void) -> (() -> Void)? {
        guard let asset = item.asset else { handler(nil, true); return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let manager = imageManager
        let requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit,
                                             options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            handler(image, !degraded)
        }
        return { manager.cancelImageRequest(requestID) }
    }

    func startCaching(_ items: [CullItem], targetSize: CGSize) {
        imageManager.startCachingImages(for: items.compactMap(\.asset), targetSize: targetSize,
                                        contentMode: .aspectFill, options: nil)
    }

    func stopCaching(_ items: [CullItem], targetSize: CGSize) {
        imageManager.stopCachingImages(for: items.compactMap(\.asset), targetSize: targetSize,
                                       contentMode: .aspectFill, options: nil)
    }

    func stopCachingAll() {
        imageManager.stopCachingImagesForAllAssets()
    }

    func hasFullPreview(for item: CullItem) -> Bool { true }
}

/// Camera-card images from the session cache. Frames not fetched yet answer
/// nil; the model bumps `imageRevision` as frames land and views re-ask.
@MainActor
final class CameraImageProvider: CullImageProvider {
    private let camera: CameraSessionModel
    private let decoded = NSCache<NSString, UIImage>()
    private let thumbs = NSCache<NSString, UIImage>()

    init(camera: CameraSessionModel) {
        self.camera = camera
        decoded.countLimit = 12
        thumbs.countLimit = 600
    }

    func requestThumbnail(for item: CullItem, targetSize: CGSize, _ handler: @escaping (UIImage?) -> Void) {
        // Sony's own thumbnail is 160×120 — soft in the grid. Once the
        // 1616px preview is cached, downsample that instead.
        let key = "thumb:\(item.id)" as NSString
        if let image = thumbs.object(forKey: key) { return handler(image) }
        handler(camera.thumbnail(forIndexID: item.id))
        guard let url = camera.previewURL(forIndexID: item.id) else { return }
        let side = max(targetSize.width, targetSize.height)
        Task {
            let image = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: url)).flatMap { Downsampler.downsample(data: $0, maxPixelSize: side) }
            }.value
            guard let image else { return }
            self.thumbs.setObject(image, forKey: key)
            handler(image)
        }
    }

    func requestPreview(for item: CullItem, targetSize: CGSize,
                        _ handler: @escaping (UIImage?, Bool) -> Void) -> (() -> Void)? {
        if let image = decoded.object(forKey: item.id as NSString) {
            handler(image, true)
            return nil
        }
        guard let url = camera.previewURL(forIndexID: item.id) else {
            // Not cached yet: show the tiny thumbnail meanwhile, ask the
            // prefetcher to hurry, and let the revision bump re-request.
            camera.prioritize(indexID: item.id)
            handler(camera.thumbnail(forIndexID: item.id), true)
            return nil
        }
        let key = item.id as NSString
        Task {
            let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            if let image { self.decoded.setObject(image, forKey: key) }
            handler(image, true)
        }
        return nil
    }

    func startCaching(_ items: [CullItem], targetSize: CGSize) {}
    func stopCaching(_ items: [CullItem], targetSize: CGSize) {}
    func stopCachingAll() { decoded.removeAllObjects(); thumbs.removeAllObjects() }

    func hasFullPreview(for item: CullItem) -> Bool { camera.previewURL(forIndexID: item.id) != nil }
}
