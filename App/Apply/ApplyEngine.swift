import CullIntent
import Photos

/// The only file in the app allowed to mutate the Photos library.
///
/// One call, one batched `performChanges`, one system dialog (hard constraint
/// 1). Rejects are deleted — landing in Recently Deleted, the 30-day safety
/// net. Keepers are left exactly as they are: no favorite flag, no album.
///
/// The caller builds an `ApplyPlan` (pure, unit-tested in VampireCore) and the
/// engine just performs what that plan says. The engine never re-derives the
/// decision — it can only check that the IDs actually resolve to assets.
struct ApplyEngine {
    struct Summary: Sendable {
        let rejectCount: Int
        let keepCount: Int
        let dryRun: Bool
    }

    enum ApplyError: Error {
        case nothingToApply
    }

    /// Performs the batched deletion for a plan that says it mutates the
    /// library. `dryRun` plans and keeps-only plans resolve the assets and
    /// report without touching anything.
    func apply(plan: ApplyPlan) async throws -> Summary {
        let rejectAssets = fetchAssets(ids: plan.rejects)
        let keepAssets = fetchAssets(ids: plan.keeps)

        guard rejectAssets.count + keepAssets.count > 0 else {
            throw ApplyError.nothingToApply
        }

        let summary = Summary(
            rejectCount: rejectAssets.count,
            keepCount: keepAssets.count,
            dryRun: plan.dryRun
        )
        if !plan.mutatesLibrary || rejectAssets.isEmpty {
            // dryRun, keeps-only, or nothing-resolvable: no library mutation.
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
