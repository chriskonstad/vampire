import Photos
import SonyMakerNotes

/// Streams the head of an asset's RAW resource and parses EXIF + MakerNotes.
///
/// This is the only place original bytes are touched, and it enforces hard
/// constraint 3: chunks accumulate in a `HeadParseSession`, and the moment the
/// parse completes (or fails, or hits the 1MB cap) the resource request is
/// cancelled. The full 60–130MB file is never pulled.
enum AssetHeadReader {
    /// Returns nil when the asset has no parseable head (unknown vendor,
    /// malformed) — the asset still gets indexed, just without camera
    /// metadata. RAW resources are preferred; EXIF JPEGs (Fuji JPEG shooters)
    /// parse the same way via their APP1 segment.
    static func readMetadata(for asset: PHAsset) async -> ARWMetadata? {
        guard let resource = rawResource(for: asset)
            ?? PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })
        else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // iCloud originals: the head still streams first

        return await withCheckedContinuation { continuation in
            let session = HeadParseSession()
            // Guards against double-resume: the data handler and completion
            // handler arrive on PhotoKit's queues and both may try to settle.
            let state = HeadRequestState()

            let requestID = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { chunk in
                let step = session.ingest(chunk)
                switch step {
                case .needMoreData:
                    return
                case .done, .failed:
                    guard state.tryFinish() else { return }
                    if case .failed(let reason) = step {
                        log.info("head parse gave up for \(asset.localIdentifier): \(reason)")
                    }
                    state.cancelRequestIfKnown()
                    if case .done(let metadata) = step {
                        continuation.resume(returning: metadata)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } completionHandler: { error in
                // Reached when the whole resource streamed without a successful
                // parse, the request errored, or our own cancellation landed.
                guard state.tryFinish() else { return }
                if let error {
                    log.info("head read failed for \(asset.localIdentifier): \(error.localizedDescription)")
                }
                continuation.resume(returning: nil)
            }
            // The data handler may already have finished before we learn the ID.
            state.registerRequest(requestID)
        }
    }

    static func rawResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { resource in
            (resource.type == .photo || resource.type == .alternatePhoto)
                && resource.uniformTypeIdentifier.lowercased().contains("raw-image")
        }
        ?? resources.first { resource in
            let name = resource.originalFilename.lowercased()
            return name.hasSuffix(".arw") || name.hasSuffix(".raf")
        }
    }
}

private final class HeadRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var requestID: PHAssetResourceDataRequestID?
    private var wantsCancel = false

    /// Atomic test-and-set; exactly one caller wins the right to resume.
    func tryFinish() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    /// Cancel the in-flight request as soon as its ID is known, whichever
    /// order the ID registration and the finish happen in.
    func cancelRequestIfKnown() {
        let id: PHAssetResourceDataRequestID? = lock.withLock {
            wantsCancel = true
            return requestID
        }
        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    func registerRequest(_ id: PHAssetResourceDataRequestID) {
        let shouldCancel: Bool = lock.withLock {
            requestID = id
            return wantsCancel
        }
        if shouldCancel {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }
}
