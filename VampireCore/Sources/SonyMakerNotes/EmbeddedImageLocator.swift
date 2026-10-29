import Foundation

/// Byte range of an embedded JPEG inside a RAW container.
public struct EmbeddedImageRange: Equatable, Sendable {
    public let offset: Int
    public let length: Int
    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }
    public var end: Int { offset + length }
}

/// The ladder of JPEGs a Sony ARW carries: a tiny thumbnail, a screen-size
/// preview, and a full-resolution JPEG. All three are located purely from the
/// IFD tags near the head of the file — you never read the pixel data to find
/// them. The wireless culling path pulls the head, locates the preview, and
/// transfers only that range (hundreds of KB) instead of the 60–130MB RAW.
public struct EmbeddedImages: Equatable, Sendable {
    /// ~160px thumbnail (IFD1). Cheapest; drives the grid.
    public var thumbnail: EmbeddedImageRange?
    /// Screen-size preview (~1616×1080 on A7RV, IFD0). The culling view; big
    /// enough for Vision (faces/aesthetics) and the AF overlay.
    public var preview: EmbeddedImageRange?
    /// Full-resolution embedded JPEG (IFD2). Optional high-quality inspect.
    public var full: EmbeddedImageRange?

    /// Best range to transfer for a cull-quality preview: the mid preview if
    /// present, else the full JPEG, else the thumbnail.
    public var bestCullingPreview: EmbeddedImageRange? {
        preview ?? full ?? thumbnail
    }
}

/// Collects every embedded JPEG (TIFF tags 0x0201 offset / 0x0202 length) by
/// walking the IFD chain and any SubIFDs, then classifies them by size.
public enum EmbeddedImageLocator {
    private enum Tag {
        static let jpegOffset: UInt16 = 0x0201   // JPEGInterchangeFormat
        static let jpegLength: UInt16 = 0x0202   // JPEGInterchangeFormatLength
        static let subIFDs: UInt16 = 0x014A
    }

    /// `head` must reach far enough to contain the IFD chain (not the pixel
    /// data). On A7RV that is the first ~150KB; a `.truncated` error means the
    /// caller should fetch more of the head and retry, exactly like
    /// `ARWHeadParser`.
    public static func locate(in head: Data) throws -> EmbeddedImages {
        let reader = try TIFF.reader(forTIFFData: head)
        var ranges: [EmbeddedImageRange] = []
        var visited = Set<Int>() // guard against malformed self-referential chains

        func collect(ifdOffset: Int) throws {
            guard ifdOffset > 0, !visited.contains(ifdOffset), visited.count < 64 else { return }
            visited.insert(ifdOffset)
            let ifd = try TIFF.parseIFD(in: reader, at: ifdOffset)

            if let offEntry = ifd.entry(tag: Tag.jpegOffset),
               let lenEntry = ifd.entry(tag: Tag.jpegLength),
               let offset = (try TIFF.unsignedValues(of: offEntry, in: reader)).first,
               let length = (try TIFF.unsignedValues(of: lenEntry, in: reader)).first,
               length > 0 {
                ranges.append(EmbeddedImageRange(offset: Int(offset), length: Int(length)))
            }

            // SubIFDs (Sony stores the full JpgFromRaw in a sub-directory on
            // some bodies).
            if let subEntry = ifd.entry(tag: Tag.subIFDs) {
                for sub in try TIFF.unsignedValues(of: subEntry, in: reader) {
                    try collect(ifdOffset: Int(sub))
                }
            }

            if ifd.nextIFDOffset > 0 {
                try collect(ifdOffset: ifd.nextIFDOffset)
            }
        }

        try collect(ifdOffset: try TIFF.firstIFDOffset(in: reader))

        // Classify by size: smallest = thumbnail, largest = full, the rest the
        // screen-size preview. Distinct sizes on every body we have.
        let sorted = ranges.sorted { $0.length < $1.length }
        var result = EmbeddedImages()
        switch sorted.count {
        case 0: break
        case 1: result.preview = sorted[0]
        case 2:
            result.thumbnail = sorted[0]
            result.preview = sorted[1]
        default:
            result.thumbnail = sorted.first
            result.full = sorted.last
            result.preview = sorted[sorted.count - 2]
        }
        return result
    }
}
