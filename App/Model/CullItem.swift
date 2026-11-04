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

    /// The pager's window, nearest first — sources that fetch over the
    /// network (camera) get these first.
    func prioritize(_ items: [CullItem])
}

extension CullImageProvider {
    func prioritize(_ items: [CullItem]) {}
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
///
/// Nothing here touches the disk or decodes on the main thread: with a
/// thousand-plus cached frames, main-thread file reads and lazy JPEG decodes
/// at draw time were what made previews crawl and stick. Repeat requests for
/// an image already loading share that load.
@MainActor
final class CameraImageProvider: CullImageProvider {
    private let camera: CameraSessionModel
    private let decoded = NSCache<NSString, UIImage>()
    private let thumbs = NSCache<NSString, UIImage>()
    private var previewWaiters: [String: [(UIImage?, Bool) -> Void]] = [:]
    private var thumbWaiters: [String: [(UIImage?) -> Void]] = [:]
    /// Grid loads, newest first: while skimming, the cells on screen now
    /// matter, not the hundreds scrolled past.
    private var thumbQueue: [(key: String, work: @Sendable () -> UIImage?)] = []
    private var thumbsRunning = 0

    init(camera: CameraSessionModel) {
        self.camera = camera
        decoded.countLimit = 16
        thumbs.countLimit = 800
    }

    func requestThumbnail(for item: CullItem, targetSize: CGSize, _ handler: @escaping (UIImage?) -> Void) {
        // Sony's own thumbnail is 160×120 — soft in the grid. Once the
        // 1616px preview is cached, a grid-size copy is made from it once
        // and kept on disk next to it.
        let key = item.id
        if let image = thumbs.object(forKey: key as NSString) { return handler(image) }
        if let image = camera.memoryThumbnail(forIndexID: key) { handler(image) }
        if thumbWaiters[key] != nil { thumbWaiters[key]!.append(handler); return }
        let preview = camera.previewURL(forIndexID: key)
        let sonyThumb = camera.hasThumbnail(forIndexID: key) ? CameraFrameCache.shared.thumbnailURL(forIndexID: key) : nil
        guard preview != nil || sonyThumb != nil else { return }
        thumbWaiters[key] = [handler]
        let grid = CameraFrameCache.shared.gridURL(forIndexID: key)
        thumbQueue.append((key, {
            if let image = Downsampler.decode(url: grid, maxPixelSize: CameraFrameCache.gridPixelSize) { return image }
            if let preview, let image = Downsampler.decode(url: preview, maxPixelSize: CameraFrameCache.gridPixelSize) {
                try? image.jpegData(compressionQuality: 0.8)?.write(to: grid, options: .atomic)
                return image
            }
            return sonyThumb.flatMap { Downsampler.decode(url: $0, maxPixelSize: 400) }
        }))
        if thumbQueue.count > 240 {
            // Scrolled far past these; drop them (re-requested on return).
            for dropped in thumbQueue.prefix(thumbQueue.count - 240) { thumbWaiters[dropped.key] = nil }
            thumbQueue.removeFirst(thumbQueue.count - 240)
        }
        pumpThumbs()
    }

    private func pumpThumbs() {
        while thumbsRunning < 3, let next = thumbQueue.popLast() {
            thumbsRunning += 1
            Task {
                let image = await Task.detached(priority: .utility, operation: next.work).value
                thumbsRunning -= 1
                // Only the real (preview-made) copy is worth keeping; a
                // Sony-thumb stand-in is replaced once the preview lands.
                if let image, camera.previewURL(forIndexID: next.key) != nil {
                    thumbs.setObject(image, forKey: next.key as NSString)
                }
                for handler in thumbWaiters.removeValue(forKey: next.key) ?? [] { handler(image) }
                pumpThumbs()
            }
        }
    }

    func requestPreview(for item: CullItem, targetSize: CGSize,
                        _ handler: @escaping (UIImage?, Bool) -> Void) -> (() -> Void)? {
        let key = item.id
        if let image = decoded.object(forKey: key as NSString) {
            handler(image, true)
            return nil
        }
        guard let url = camera.previewURL(forIndexID: key) else {
            // Not cached yet: show the tiny thumbnail meanwhile (the pager
            // has already asked the prefetcher for its window) and let the
            // revision bump re-request.
            handler(camera.memoryThumbnail(forIndexID: key) ?? thumbs.object(forKey: key as NSString), true)
            return nil
        }
        if previewWaiters[key] != nil { previewWaiters[key]!.append(handler); return nil }
        previewWaiters[key] = [handler]
        let side = max(targetSize.width, targetSize.height)
        Task {
            // Fully decoded off the main thread (a lazily decoded UIImage
            // would decode on first draw — on the main thread, mid-swipe).
            let image = await Task.detached(priority: .userInitiated) {
                Downsampler.decode(url: url, maxPixelSize: side)
            }.value
            if let image {
                decoded.setObject(image, forKey: key as NSString)
            } else {
                camera.previewMissing(indexID: key)  // purged by iOS: re-fetch
            }
            for waiter in previewWaiters.removeValue(forKey: key) ?? [] { waiter(image, true) }
        }
        return nil
    }

    func startCaching(_ items: [CullItem], targetSize: CGSize) {}
    func stopCaching(_ items: [CullItem], targetSize: CGSize) {}
    /// Kept on purpose: the caches are keyed by stable IDs, and a card
    /// re-listing (every reconnect) mustn't throw away decoded images.
    /// NSCache sheds them under memory pressure.
    func stopCachingAll() {}

    func hasFullPreview(for item: CullItem) -> Bool { camera.previewURL(forIndexID: item.id) != nil }

    func prioritize(_ items: [CullItem]) { camera.prioritize(indexIDs: items.map(\.id)) }
}
