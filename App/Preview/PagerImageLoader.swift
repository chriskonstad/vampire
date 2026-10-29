import UIKit
import ImageIO

import RequestScheduling

/// Screen-scale images for the full-screen pager.
///
/// Hard constraint 2 lives here: the pager shows a cheap embedded preview
/// (Photos' for library sessions, the camera's screennail for camera
/// sessions) at screen scale — never a CIRAWFilter decode.
///
/// @Observable so views re-render when images land: they read `revision`,
/// which bumps on every cache insert. (A previous design forwarded loads
/// into a @State counter via a stored closure; SwiftUI dropped those
/// invalidations on device — images sat cached but undrawn until any tap.)
@MainActor
@Observable
final class PagerImageLoader {
    /// Bumped whenever an image lands in the cache.
    private(set) var revision = 0

    @ObservationIgnored private let provider: CullImageProvider
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var inFlight: [String: (() -> Void)?] = [:]
    @ObservationIgnored private var scheduler = RequestScheduler<String>()
    @ObservationIgnored private var itemsByID: [String: CullItem] = [:]
    /// Items whose cached image is the real preview, not a stand-in.
    @ObservationIgnored private var full: Set<String> = []

    /// Screen-bound pixel size; anything bigger is wasted decode.
    @ObservationIgnored private let targetSize: CGSize

    init(provider: CullImageProvider) {
        self.provider = provider
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        targetSize = CGSize(width: screen.width * scale, height: screen.height * scale)
        cache.countLimit = 9 // current ± a few neighbors; previews are screen-size
    }

    func cachedImage(for itemID: String) -> UIImage? {
        cache.object(forKey: itemID as NSString)
    }

    /// Pager moved: current frame first, neighbors behind it, cancel the rest.
    func focus(on index: Int, in items: [CullItem]) {
        guard items.indices.contains(index) else { return }
        for (_, cancel) in inFlight { cancel?() }
        inFlight.removeAll()
        scheduler.advanceGeneration()

        itemsByID = [:]
        let window = max(0, index - 3) ... min(items.count - 1, index + 3)
        for i in window {
            itemsByID[items[i].id] = items[i]
        }

        scheduler.focus(
            current: items[index].id,
            next: index + 1 < items.count ? items[index + 1].id : nil,
            previous: index > 0 ? items[index - 1].id : nil,
            prefetch: window
                .filter { abs($0 - index) > 1 }
                .map { items[$0].id }
        )
        pump()
    }

    private func pump() {
        while inFlight.count < 2, let request = scheduler.dequeue() {
            start(request.key)
        }
    }

    private func start(_ itemID: String) {
        guard !full.contains(itemID) || cache.object(forKey: itemID as NSString) == nil,
              inFlight[itemID] == nil,
              let item = itemsByID[itemID] else {
            pumpIfIdle()
            return
        }
        inFlight[itemID] = .some(nil)
        var finished = false
        let cancel = provider.requestPreview(for: item, targetSize: targetSize) { [weak self] image, isFinal in
            guard let self else { return }
            if let image {
                self.cache.setObject(image, forKey: itemID as NSString)
                self.revision += 1
            }
            if isFinal {
                finished = true
                if self.provider.hasFullPreview(for: item) { self.full.insert(itemID) }
                self.inFlight.removeValue(forKey: itemID)
                self.pump()
            }
        }
        if !finished { inFlight[itemID] = cancel }
    }

    private func pumpIfIdle() {
        if !scheduler.isEmpty { pump() }
    }
}

/// ImageIO downsampling for "inspect"-grade loads from file data: decodes at
/// `maxPixelSize`, never the full 61MP (kCGImageSourceThumbnailMaxPixelSize).
/// Unused by the scroll path; here for the explicit inspect action.
enum Downsampler {
    static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
