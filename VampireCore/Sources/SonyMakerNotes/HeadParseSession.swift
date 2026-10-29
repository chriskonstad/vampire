import Foundation

/// Pure-logic accumulator for streamed head-of-file parsing.
///
/// The app feeds chunks from `PHAssetResourceManager.requestData` into
/// `ingest`; the moment it returns anything other than `.needMoreData`, the
/// caller must cancel the resource request. This is the mechanism that keeps
/// us from ever pulling a full 60–130MB ARW just to read a focus box.
public final class HeadParseSession {
    public enum Step: Sendable {
        case needMoreData
        case done(ARWMetadata)
        /// Malformed file, or the head cap was reached without a complete parse.
        /// Either way: stop reading, index the asset without MakerNotes data.
        case failed(String)
    }

    private var buffer = Data()
    private let maxHeadLength: Int

    public init(maxHeadLength: Int = ARWHeadParser.recommendedHeadLength) {
        self.maxHeadLength = maxHeadLength
    }

    public var bytesIngested: Int { buffer.count }

    public func ingest(_ chunk: Data) -> Step {
        buffer.append(chunk)
        do {
            return .done(try CameraHeadParser.parse(head: buffer))
        } catch ARWParseError.truncated(let needed) {
            if buffer.count >= maxHeadLength {
                return .failed("metadata not within first \(maxHeadLength) bytes (needed offset \(needed))")
            }
            return .needMoreData
        } catch {
            return .failed("\(error)")
        }
    }
}
