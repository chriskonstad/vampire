import SwiftUI
import UIKit

import SonyMakerNotes

/// One pager page: a UIScrollView-backed photo with native pinch-to-zoom,
/// pan-while-zoomed, double-tap zoom-to-AF, and the AF box overlay drawn
/// *inside* the zooming view so it tracks the image.
///
/// UIScrollView instead of SwiftUI gestures on purpose: at 1× the scroll view
/// has nothing to pan, so horizontal swipes fall through to the TabView and
/// paging works; zoomed in, the scroll view owns the drag. No gesture fights.
struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    let focusLocation: FocusLocation?
    var salientRect: NormalizedRect?
    var horizonDegrees: Double?
    let showsAFOverlay: Bool
    /// Fires on zoomed-in/out transitions so the pager can disable paging
    /// while zoomed (Photos behavior: zoomed drags pan, never page).
    var onZoomChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        PhotoZoomScrollView()
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.configure(
            image: image,
            focusLocation: focusLocation,
            salientRect: salientRect,
            horizonDegrees: horizonDegrees,
            showsOverlay: showsAFOverlay
        )
    }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    private let afBox = UIView()
    /// Attention-saliency box: where the eye goes. Dashed so it reads as
    /// informational next to the solid AF box (where the camera focused).
    private let salientBox = UIView()
    private let salientBorder = CAShapeLayer()
    /// Measured horizon vs level, drawn across the photo itself.
    private let horizonView = UIView()
    private let levelLine = CAShapeLayer()
    private let horizonLine = CAShapeLayer()
    private var focusLocation: FocusLocation?
    private var salientRect: NormalizedRect?
    private var horizonDegrees: Double?
    private var showsOverlay = true
    /// Press-and-hold peek: the AF box hides while the finger is down so the
    /// subject underneath is checkable, and returns on release.
    private var isPeeking = false
    private var lastLayoutSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleToFill // frame is computed aspect-fit
        addSubview(imageView)

        // Semi-transparent so the box marks the spot without hiding what's
        // under it — press-and-hold still clears it entirely.
        afBox.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.55).cgColor
        afBox.layer.borderWidth = 1.5
        afBox.isUserInteractionEnabled = false
        imageView.addSubview(afBox)

        salientBorder.strokeColor = UIColor.white.withAlphaComponent(0.38).cgColor
        salientBorder.fillColor = nil
        salientBorder.lineWidth = 1.5
        salientBorder.lineDashPattern = [5, 4]
        salientBox.layer.addSublayer(salientBorder)
        salientBox.isUserInteractionEnabled = false
        imageView.addSubview(salientBox)

        // Artificial horizon: faint dashed level reference + the measured
        // horizon line, drawn over the photo where the tilt actually is.
        levelLine.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        levelLine.lineWidth = 1
        levelLine.lineDashPattern = [4, 4]
        horizonLine.strokeColor = UIColor.systemOrange.withAlphaComponent(0.5).cgColor
        horizonLine.lineWidth = 1.5
        horizonView.layer.addSublayer(levelLine)
        horizonView.layer.addSublayer(horizonLine)
        horizonView.clipsToBounds = true
        horizonView.isUserInteractionEnabled = false
        imageView.addSubview(horizonView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.2
        press.cancelsTouchesInView = false
        press.delegate = self // simultaneous with pinch/pan/double-tap
        addGestureRecognizer(press)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage?, focusLocation: FocusLocation?, salientRect: NormalizedRect?, horizonDegrees: Double?, showsOverlay: Bool) {
        if imageView.image !== image {
            imageView.image = image
            zoomScale = 1
            lastLayoutSize = .zero // force re-fit
            setNeedsLayout()
        }
        self.focusLocation = focusLocation
        self.salientRect = salientRect
        self.horizonDegrees = horizonDegrees
        self.showsOverlay = showsOverlay
        layoutAFBox()
        layoutSalientBox()
        layoutHorizon()
        updateGestureOwnership() // zoom may have been reset programmatically
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }

        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            layoutAFBox()
            layoutSalientBox()
            layoutHorizon()
        }
        centerContent()
    }

    /// Level reference + measured horizon through the image center; only
    /// drawn when the photo is visibly off (≥2°).
    private func layoutHorizon() {
        guard showsOverlay, !isPeeking,
              let degrees = horizonDegrees, abs(degrees) >= 2,
              imageView.bounds.width > 0 else {
            horizonView.isHidden = true
            return
        }
        horizonView.isHidden = false
        horizonView.frame = imageView.bounds

        let center = CGPoint(x: horizonView.bounds.midX, y: horizonView.bounds.midY)
        // Long enough to span the frame at any rotation.
        let reach = max(horizonView.bounds.width, horizonView.bounds.height)

        let level = UIBezierPath()
        level.move(to: CGPoint(x: center.x - reach, y: center.y))
        level.addLine(to: CGPoint(x: center.x + reach, y: center.y))
        levelLine.frame = horizonView.bounds
        levelLine.path = level.cgPath

        // Vision's angle is the horizon's angle in the image.
        let radians = -degrees * .pi / 180
        let dx = cos(radians) * reach
        let dy = sin(radians) * reach
        let horizon = UIBezierPath()
        horizon.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
        horizon.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        horizonLine.frame = horizonView.bounds
        horizonLine.path = horizon.cgPath
    }

    private func layoutSalientBox() {
        guard showsOverlay, !isPeeking,
              let rect = salientRect,
              imageView.bounds.width > 0 else {
            salientBox.isHidden = true
            return
        }
        salientBox.isHidden = false
        salientBox.frame = CGRect(
            x: imageView.bounds.width * rect.x,
            y: imageView.bounds.height * rect.y,
            width: imageView.bounds.width * rect.width,
            height: imageView.bounds.height * rect.height
        )
        salientBorder.frame = salientBox.bounds
        salientBorder.path = UIBezierPath(rect: salientBox.bounds).cgPath
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isPeeking = true
        case .ended, .cancelled, .failed:
            isPeeking = false
        default:
            return
        }
        layoutAFBox()
        layoutSalientBox()
        layoutHorizon()
    }

    /// AF box in imageView coordinates; it scales with the zoom transform.
    private func layoutAFBox() {
        guard showsOverlay, !isPeeking,
              let focus = focusLocation,
              let point = focus.normalizedPoint,
              imageView.bounds.width > 0 else {
            afBox.isHidden = true
            return
        }
        afBox.isHidden = false
        let size: CGSize
        if let frame = focus.normalizedFrame {
            size = CGSize(
                width: imageView.bounds.width * frame.width,
                height: imageView.bounds.height * frame.height
            )
        } else {
            // No FocusFrameSize tag: a fixed fraction of the frame.
            let side = imageView.bounds.width * 0.05
            size = CGSize(width: side, height: side)
        }
        afBox.frame = CGRect(
            x: imageView.bounds.width * point.x - size.width / 2,
            y: imageView.bounds.height * point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateGestureOwnership()
    }

    var onZoomChange: ((Bool) -> Void)?
    private var lastReportedZoomedIn = false

    /// Photos-app behavior: while zoomed in, this scroll view owns EVERY
    /// drag. Neither `.scrollDisabled` nor nested-scroll deference stops the
    /// paged TabView (verified empirically), so the ancestor scroll views —
    /// the TabView's internal pager and the burst stack — are disabled
    /// directly while zoomed and re-enabled at 1×.
    private func updateGestureOwnership() {
        let zoomedIn = zoomScale > minimumZoomScale + 0.01
        alwaysBounceHorizontal = zoomedIn
        alwaysBounceVertical = zoomedIn
        setAncestorScrolling(enabled: !zoomedIn)
        if zoomedIn != lastReportedZoomedIn {
            lastReportedZoomedIn = zoomedIn
            onZoomChange?(zoomedIn)
        }
    }

    private func setAncestorScrolling(enabled: Bool) {
        var view: UIView? = superview
        while let current = view {
            if let scroll = current as? UIScrollView {
                scroll.isScrollEnabled = enabled
            }
            view = current.superview
        }
    }

    /// Never leave ancestors disabled if this page disappears while zoomed
    /// (dismissal, recycling).
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            setAncestorScrolling(enabled: true)
        }
    }

    // MARK: - Double tap: the sharpness check

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom into the AF point when the camera recorded one; otherwise the
        // tapped spot.
        let target: CGPoint
        if let point = focusLocation?.normalizedPoint {
            target = CGPoint(
                x: imageView.bounds.width * point.x,
                y: imageView.bounds.height * point.y
            )
        } else {
            target = recognizer.location(in: imageView)
        }
        let scale: CGFloat = 4
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(
            to: CGRect(
                x: target.x - size.width / 2,
                y: target.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            animated: true
        )
    }
}
