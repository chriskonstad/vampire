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
    /// Bumped whenever an image lands.
    private(set) var revision = 0
    /// Frames within reach of the current one (±4 in display order). Frame
    /// views read this themselves to decide whether to watch `revision` —
    /// a nearness flag computed by the pager went stale inside paged
    /// TabView content (not rebuilt as you move), leaving a burst's first
    /// frame blank until you scrolled away and back.
    private(set) var window: Set<String> = []

    @ObservationIgnored private let provider: CullImageProvider
    /// What to load, keep, cancel and re-request — pure and unit-tested
    /// (VampireCore `WindowedLoader`); this class only carries it out.
    @ObservationIgnored private var core = WindowedLoader<String, UIImage>()
    @ObservationIgnored private var cancels: [WindowedLoader<String, UIImage>.Request: () -> Void] = [:]
    @ObservationIgnored private var itemsByID: [String: CullItem] = [:]

    /// Viewport-bound pixel size; anything bigger is wasted decode. Starts
    /// at a typical large iPhone and follows the pager's real viewport via
    /// `updateViewport` — on iPhone Duo the app moves between a 5.4" and a
    /// 7.6" screen as it folds, so a size fixed at creation (the old
    /// UIScreen.main read) would leave unfolded previews soft.
    @ObservationIgnored private var targetSize = CGSize(width: 1320, height: 2868)

    init(provider: CullImageProvider) {
        self.provider = provider
    }

    /// The pager's size in points and its display scale. Growing past what's
    /// cached re-requests the frames in view at the new size.
    func updateViewport(_ size: CGSize, scale: CGFloat) {
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixels.width > 0, pixels.height > 0, pixels != targetSize else { return }
        let grew = pixels.width > targetSize.width || pixels.height > targetSize.height
        targetSize = pixels
        if grew { core.invalidateAll() }  // re-request in view at the sharper size
    }

    func cachedImage(for itemID: String) -> UIImage? {
        core.image(for: itemID)
    }

    /// Pager moved (or new frames landed): current frame first, neighbors
    /// behind it, nearest first for sources that fetch over the network.
    func focus(on index: Int, in items: [CullItem]) {
        guard items.indices.contains(index) else { return }
        let range = max(0, index - core.radius) ... min(items.count - 1, index + core.radius)
        for i in range { itemsByID[items[i].id] = items[i] }
        provider.prioritize(range.sorted { abs($0 - index) < abs($1 - index) }.map { items[$0] })
        apply(core.focus(on: index, in: items.map(\.id)))
        if core.window != window { window = core.window }
        itemsByID = itemsByID.filter { core.window.contains($0.key) }
    }

    private func apply(_ effects: [WindowedLoader<String, UIImage>.Effect]) {
        for effect in effects {
            switch effect {
            case .cancel(let request):
                cancels.removeValue(forKey: request)?()
            case .start(let request):
                guard let item = itemsByID[request.key] else { continue }
                var finished = false
                let cancel = provider.requestPreview(for: item, targetSize: targetSize) { [weak self] image, isFinal in
                    guard let self else { return }
                    if isFinal {
                        finished = true
                        self.cancels[request] = nil
                    }
                    let next = self.core.deliver(request, image: image, isFinal: isFinal,
                                                 isFull: isFinal && self.provider.hasFullPreview(for: item))
                    if image != nil { self.revision += 1 }
                    self.apply(next)
                }
                if !finished, let cancel { cancels[request] = cancel }
            }
        }
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
