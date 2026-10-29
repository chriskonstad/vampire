import XCTest
@testable import BurstClustering

final class BurstClusteringTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func asset(_ id: String, at seconds: TimeInterval, print featurePrint: [Float]? = nil) -> ClusterableAsset {
        ClusterableAsset(id: id, creationDate: t0.addingTimeInterval(seconds), featurePrint: featurePrint)
    }

    // MARK: - Time clustering

    func testTenFPSBurstGroupsTogether() {
        // 10fps drive: 100ms apart — well under the 2s threshold.
        let assets = (0 ..< 10).map { asset("burst-\($0)", at: Double($0) * 0.1) }
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 10)
        XCTAssertEqual(groups[0].id, "burst-0")
    }

    func testGapSplitsClusters() {
        let assets = [
            asset("a", at: 0), asset("b", at: 1),
            asset("c", at: 60), asset("d", at: 61),
        ]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.map(\.assetIDs), [["a", "b"], ["c", "d"]])
    }

    func testUnsortedInputIsSortedChronologically() {
        let assets = [asset("b", at: 1), asset("a", at: 0), asset("c", at: 0.5)]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups[0].assetIDs, ["a", "c", "b"])
    }

    func testChainSemanticsTotalSpanIsUnbounded() {
        // A burst is a CHAIN: each consecutive gap under the threshold. The
        // total span doesn't matter — 20 frames 0.6s apart (11.4s end to end)
        // are one burst at a 1s threshold; a single 1.2s gap breaks the chain.
        let params = ClusteringParameters(timeGapThreshold: 1.0)
        let chain = (0 ..< 20).map { asset("c\($0)", at: Double($0) * 0.6) }
        XCTAssertEqual(BurstClusterer.cluster(chain, parameters: params).count, 1)

        var broken = (0 ..< 10).map { asset("a\($0)", at: Double($0) * 0.6) }
        broken += (0 ..< 10).map { asset("b\($0)", at: 5.4 + 1.2 + Double($0) * 0.6) }
        let groups = BurstClusterer.cluster(broken, parameters: params)
        XCTAssertEqual(groups.map(\.count), [10, 10])
    }

    func testSubsecondPrecisionMatters() {
        // Frames 1.9s apart group; 2.1s apart split.
        let groups = BurstClusterer.cluster([
            asset("a", at: 0), asset("b", at: 1.9), asset("c", at: 4.0),
        ])
        XCTAssertEqual(groups.map(\.assetIDs), [["a", "b"], ["c"]])
    }

    // MARK: - Feature-print refinement

    func testSceneChangeSplitsTimeCluster() {
        // Continuous shooting but the subject changed mid-burst.
        let sceneA: [Float] = [1, 0, 0, 0]
        let sceneB: [Float] = [0, 1, 0, 0] // distance √2 ≈ 1.41 > splitDistance 1.2
        let assets = [
            asset("a1", at: 0.0, print: sceneA),
            asset("a2", at: 0.1, print: sceneA),
            asset("b1", at: 0.2, print: sceneB),
            asset("b2", at: 0.3, print: sceneB),
        ]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.map(\.assetIDs), [["a1", "a2"], ["b1", "b2"]])
    }

    func testSimilarAdjacentClustersMerge() {
        // "Walked around the subject": >2s gaps but visually continuous.
        let scene: [Float] = [1, 0, 0, 0]
        let near: [Float] = [0.9, 0.1, 0, 0] // distance ≈ 0.14 < mergeDistance
        let assets = [
            asset("a", at: 0, print: scene),
            asset("b", at: 5, print: near),
            asset("c", at: 10, print: scene),
        ]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].assetIDs, ["a", "b", "c"])
    }

    func testMergeRespectsMaxTimeGap() {
        let scene: [Float] = [1, 0, 0, 0]
        let assets = [
            asset("a", at: 0, print: scene),
            asset("b", at: 120, print: scene), // identical scene, but 2 minutes later
        ]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.count, 2)
    }

    func testMissingPrintsFallBackToTimeOnly() {
        // Indexing still running: no prints, time clustering must still work.
        let assets = [asset("a", at: 0), asset("b", at: 0.5), asset("c", at: 30)]
        let groups = BurstClusterer.cluster(assets)
        XCTAssertEqual(groups.map(\.assetIDs), [["a", "b"], ["c"]])
    }

    func testEmptyInput() {
        XCTAssertEqual(BurstClusterer.cluster([]), [])
    }

    // MARK: - Distance + find similar

    func testDistanceMismatchedShapesIsNil() {
        XCTAssertNil(featurePrintDistance([1, 2], [1, 2, 3]))
        XCTAssertNil(featurePrintDistance([], []))
    }

    func testNearestAssetsOrdersByDistanceAndExcludesSelf() {
        let assets = [
            asset("self", at: 0, print: [1, 0]),
            asset("close", at: 1, print: [0.9, 0]),
            asset("far", at: 2, print: [0, 1]),
            asset("noprint", at: 3),
        ]
        let results = nearestAssets(to: [1, 0], in: assets, excluding: "self")
        XCTAssertEqual(results.map(\.id), ["close", "far"])
        XCTAssertLessThan(results[0].distance, results[1].distance)
    }
}
