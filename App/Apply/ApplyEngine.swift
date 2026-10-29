import Photos

/// The only file in the app allowed to mutate the Photos library.
///
/// One call, one batched `performChanges`, one system dialog (hard constraint
/// 1). Rejects are deleted — landing in Recently Deleted, the 30-day safety
/// net. Keepers are left exactly as they are: no favorite flag, no album.
struct ApplyEngine {
    struct Summary: Sendable {
        let rejectCount: Int
        let keepCount: Int
        let dryRun: Bool
    }

    enum ApplyError: Error {
        case nothingToApply
    }

    /// `dryRun` resolves the asset IDs and reports what *would* happen without
    /// touching the library — exercised in tests and wired to a long-press on
    /// the Apply button.
    func apply(rejects: [String], keeps: [String], dryRun: Bool) async throws -> Summary {
        let rejectAssets = fetchAssets(ids: rejects)
        let keepAssets = fetchAssets(ids: keeps)

        guard rejectAssets.count + keepAssets.count > 0 else {
            throw ApplyError.nothingToApply
        }

        let summary = Summary(
            rejectCount: rejectAssets.count,
            keepCount: keepAssets.count,
            dryRun: dryRun
        )
        if dryRun || rejectAssets.isEmpty {
            // Keeps require no library mutation at all.
            return summary
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(rejectAssets as NSArray)
        }
        return summary
    }

    private func fetchAssets(ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }
}
