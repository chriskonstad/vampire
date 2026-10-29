import Foundation

/// Maps normalized sensor-space geometry (how MakerNotes record AF points and
/// faces) into the upright display space a viewer shows after applying the
/// EXIF orientation. Portrait shots are stored sideways with orientation 6 or
/// 8, so an un-mapped AF box lands in the wrong place.
public enum DisplayOrientation {
    /// Normalized point (top-left origin) in display space.
    public static func point(_ p: (x: Double, y: Double), exif orientation: Int?) -> (x: Double, y: Double) {
        switch orientation ?? 1 {
        case 3: return (1 - p.x, 1 - p.y)  // 180°
        case 6: return (1 - p.y, p.x)      // display = stored rotated 90° CW
        case 8: return (p.y, 1 - p.x)      // display = stored rotated 90° CCW
        default: return p                  // 1 (and mirrored variants, unused by cameras)
        }
    }

    /// Normalized rect (top-left origin) in display space.
    public static func rect(_ r: NormalizedRect, exif orientation: Int?) -> NormalizedRect {
        let a = point((r.x, r.y), exif: orientation)
        let b = point((r.x + r.width, r.y + r.height), exif: orientation)
        return NormalizedRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension FocusLocation {
    /// This AF point/frame re-expressed in the upright display frame for an
    /// EXIF orientation: axes (and the image/frame dimensions) swap for
    /// 6/8. Everything the UI draws on is upright, so records store this.
    public func displayOriented(exif orientation: Int?) -> FocusLocation {
        let w = imageWidth, h = imageHeight
        switch orientation ?? 1 {
        case 3:
            return FocusLocation(imageWidth: w, imageHeight: h, x: w - x, y: h - y,
                                 frameWidth: frameWidth, frameHeight: frameHeight)
        case 6:  // display = stored rotated 90° CW
            return FocusLocation(imageWidth: h, imageHeight: w, x: h - y, y: x,
                                 frameWidth: frameHeight, frameHeight: frameWidth)
        case 8:  // display = stored rotated 90° CCW
            return FocusLocation(imageWidth: h, imageHeight: w, x: y, y: w - x,
                                 frameWidth: frameHeight, frameHeight: frameWidth)
        default:
            return self
        }
    }
}
