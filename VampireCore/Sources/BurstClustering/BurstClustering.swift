import Foundation

/// Input to clustering: the few index fields it needs, decoupled from PHAsset
/// (hard constraint 6: PHAsset.burstIdentifier only covers iPhone bursts, so
/// camera imports are clustered here, from creation time + feature prints).
public struct ClusterableAsset: Sendable {
    public let id: String
    public let creationDate: Date
    /// Vision feature print vector. Optional — indexing streams in behind the
    /// UI, so clustering must work (time-only) before prints exist and improve
    /// once they arrive.
    public let featurePrint: [Float]?

    public init(id: String, creationDate: Date, featurePrint: [Float]? = nil) {
        self.id = id
        self.creationDate = creationDate
        self.featurePrint = featurePrint
    }
}

public struct BurstGroup: Equatable, Sendable {
    /// Stable across re-clustering runs as long as membership of the first
    /// frame is stable: the ID of the earliest asset in the group.
    public let id: String
    public let assetIDs: [String]

    public var count: Int { assetIDs.count }
}

public struct ClusteringParameters: Sendable {
    /// Consecutive-frame gap that keeps two assets in one time cluster.
    /// ~2s catches 10fps drive bursts with margin; ARW EXIF has subsecond
    /// precision so real bursts sit far under this.
    public var timeGapThreshold: TimeInterval
    /// Feature-print distance between consecutive frames above which a time
    /// cluster is split (scene changed mid-burst).
    public var splitDistance: Float
    /// Distance between adjacent clusters' boundary frames below which they
    /// merge despite a time gap ("walked around the subject").
    public var mergeDistance: Float
    /// Adjacent clusters further apart than this never merge, however similar.
    public var mergeMaxTimeGap: TimeInterval

    public init(
        timeGapThreshold: TimeInterval = 2.0,
        splitDistance: Float = 1.2,
        mergeDistance: Float = 0.55,
        mergeMaxTimeGap: TimeInterval = 30
    ) {
        self.timeGapThreshold = timeGapThreshold
        self.splitDistance = splitDistance
        self.mergeDistance = mergeDistance
        self.mergeMaxTimeGap = mergeMaxTimeGap
    }
}

/// Euclidean distance between two feature-print vectors, nil if shapes differ
/// (different Vision revisions must not silently compare).
public func featurePrintDistance(_ a: [Float], _ b: [Float]) -> Float? {
    guard a.count == b.count, !a.isEmpty else { return nil }
    var sum: Float = 0
    for i in a.indices {
        let d = a[i] - b[i]
        sum += d * d
    }
    return sum.squareRoot()
}

public enum BurstClusterer {
    /// Groups assets into bursts. Output preserves chronological order both
    /// across groups and within each group. Single-frame "groups" are emitted
    /// too — the UI decides what counts as a burst worth bundling (count > 1).
    public static func cluster(
        _ assets: [ClusterableAsset],
        parameters: ClusteringParameters = ClusteringParameters()
    ) -> [BurstGroup] {
        guard !assets.isEmpty else { return [] }
        let sorted = assets.sorted { $0.creationDate < $1.creationDate }

        // Pass 1: split on time gaps.
        var clusters: [[ClusterableAsset]] = [[sorted[0]]]
        for asset in sorted.dropFirst() {
            let previous = clusters[clusters.count - 1].last!
            if asset.creationDate.timeIntervalSince(previous.creationDate) <= parameters.timeGapThreshold {
                clusters[clusters.count - 1].append(asset)
            } else {
                clusters.append([asset])
            }
        }

        // Pass 2: split a time cluster where consecutive prints diverge.
        clusters = clusters.flatMap { splitOnSceneChange($0, parameters: parameters) }

        // Pass 3: merge visually-continuous adjacent clusters.
        clusters = mergeSimilarAdjacent(clusters, parameters: parameters)

        return clusters.map { members in
            BurstGroup(id: members[0].id, assetIDs: members.map(\.id))
        }
    }

    private static func splitOnSceneChange(
        _ cluster: [ClusterableAsset],
        parameters: ClusteringParameters
    ) -> [[ClusterableAsset]] {
        guard cluster.count > 1 else { return [cluster] }
        var result: [[ClusterableAsset]] = [[cluster[0]]]
        for asset in cluster.dropFirst() {
            let previous = result[result.count - 1].last!
            if let a = previous.featurePrint, let b = asset.featurePrint,
               let distance = featurePrintDistance(a, b),
               distance > parameters.splitDistance {
                result.append([asset])
            } else {
                // Missing prints (still indexing) keep the time grouping.
                result[result.count - 1].append(asset)
            }
        }
        return result
    }

    private static func mergeSimilarAdjacent(
        _ clusters: [[ClusterableAsset]],
        parameters: ClusteringParameters
    ) -> [[ClusterableAsset]] {
        guard clusters.count > 1 else { return clusters }
        var result: [[ClusterableAsset]] = [clusters[0]]
        for cluster in clusters.dropFirst() {
            let previous = result[result.count - 1]
            let gap = cluster[0].creationDate.timeIntervalSince(previous.last!.creationDate)
            if gap <= parameters.mergeMaxTimeGap,
               let a = previous.last!.featurePrint, let b = cluster[0].featurePrint,
               let distance = featurePrintDistance(a, b),
               distance < parameters.mergeDistance {
                result[result.count - 1] += cluster
            } else {
                result.append(cluster)
            }
        }
        return result
    }
}

/// Linear-scan "find similar" over stored feature prints. Prints are tiny, a
/// shoot is thousands of frames — brute force is fine for v1.
public func nearestAssets(
    to query: [Float],
    in assets: [ClusterableAsset],
    limit: Int = 20,
    excluding excludedID: String? = nil
) -> [(id: String, distance: Float)] {
    assets.compactMap { asset -> (String, Float)? in
        guard asset.id != excludedID,
              let print = asset.featurePrint,
              let distance = featurePrintDistance(query, print) else { return nil }
        return (asset.id, distance)
    }
    .sorted { $0.1 < $1.1 }
    .prefix(limit)
    .map { (id: $0.0, distance: $0.1) }
}
