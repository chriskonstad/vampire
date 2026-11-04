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
    /// Frames within reach of the current one (±4 in display order). Frame
    /// views read this themselves to decide whether to watch `revision` —
    /// a nearness flag computed by the pager went stale inside paged
    /// TabView content (not rebuilt as you move), leaving a burst's first
    /// frame blank until you scrolled away and back.
    private(set) var window: Set<String> = []

    @ObservationIgnored private let provider: CullImageProvider
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    /// Token tells a late completion apart from a newer request for the
    /// same frame (some providers can't cancel).
    @ObservationIgnored private var inFlight: [String: (token: UUID, cancel: (() -> Void)?)] = [:]
    @ObservationIgnored private var scheduler = RequestScheduler<String>()
    @ObservationIgnored private var itemsByID: [String: CullItem] = [:]
    /// Items whose cached image is the real preview, not a stand-in.
    @ObservationIgnored private var full: Set<String> = []

    /// Viewport-bound pixel size; anything bigger is wasted decode. Starts
    /// at a typical large iPhone and follows the pager's real viewport via
    /// `updateViewport` — on iPhone Duo the app moves between a 5.4" and a
    /// 7.6" screen as it folds, so a size fixed at creation (the old
    /// UIScreen.main read) would leave unfolded previews soft.
    @ObservationIgnored private var targetSize = CGSize(width: 1320, height: 2868)

    init(provider: CullImageProvider) {
        self.provider = provider
        cache.countLimit = 12 // current ± 4 neighbors + slack; previews are screen-size
    }

    /// The pager's size in points and its display scale. Growing past what's
    /// cached re-requests the frames in view at the new size.
    func updateViewport(_ size: CGSize, scale: CGFloat) {
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixels.width > 0, pixels.height > 0, pixels != targetSize else { return }
        let grew = pixels.width > targetSize.width || pixels.height > targetSize.height
        targetSize = pixels
        if grew { full.removeAll() }  // re-request in view at the sharper size
    }

    func cachedImage(for itemID: String) -> UIImage? {
        cache.object(forKey: itemID as NSString)
    }

    /// Pager moved (or new frames landed): current frame first, neighbors
    /// behind it. Loads still inside the window keep going — cancelling and
    /// restarting them on every refocus (each camera frame landing triggers
    /// one) starved the frame on screen.
    func focus(on index: Int, in items: [CullItem]) {
        guard items.indices.contains(index) else { return }
        let window = max(0, index - 4) ... min(items.count - 1, index + 4)
        itemsByID = [:]
        for i in window {
            itemsByID[items[i].id] = items[i]
        }
        let ids = Set(itemsByID.keys)
        if ids != self.window { self.window = ids }
        for (id, entry) in inFlight where itemsByID[id] == nil {
            entry.cancel?()
            inFlight[id] = nil
        }
        scheduler.advanceGeneration()
        provider.prioritize(window.sorted { abs($0 - index) < abs($1 - index) }.map { items[$0] })

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
        while inFlight.count < 3, let request = scheduler.dequeue() {
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
        let token = UUID()
        inFlight[itemID] = (token, nil)
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
                if self.inFlight[itemID]?.token == token { self.inFlight.removeValue(forKey: itemID) }
                self.pump()
            }
        }
        if !finished, inFlight[itemID]?.token == token { inFlight[itemID] = (token, cancel) }
    }

    private func pumpIfIdle() {
        if !scheduler.isEmpty { pump() }
    }
}

/// ImageIO downsampling for "inspect"-grade loads from file data: decodes at
/// `maxPixelSize`, never the full 61MP (kCGImageSourceThumbnailMaxPixelSize).
/// Unused by the scroll path; here for the explicit inspect action.
enum Downsampler {
    /// Decodes a file at most `maxPixelSize` on its long side, fully (not
    /// lazily), so the result draws without further work. Call off-main.
    static func decode(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }

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
