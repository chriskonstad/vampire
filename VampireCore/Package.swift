// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VampireCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14), // pure-logic targets unit-test on macOS; no device needed
    ],
    products: [
        .library(name: "SonyMakerNotes", targets: ["SonyMakerNotes"]),
        .library(name: "CullIntent", targets: ["CullIntent"]),
        .library(name: "BurstClustering", targets: ["BurstClustering"]),
        .library(name: "RequestScheduling", targets: ["RequestScheduling"]),
        .library(name: "VampireIndex", targets: ["VampireIndex"]),
        .library(name: "PTP", targets: ["PTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        // Sony ARW head-of-file parser: TIFF/IFD walk + MakerNotes (FocusLocation 0x2027).
        .target(name: "SonyMakerNotes"),
        .testTarget(
            name: "SonyMakerNotesTests",
            dependencies: ["SonyMakerNotes"]
        ),

        // Append-only intent log with undo/redo. Pure logic; persistence via VampireIndex.
        .target(name: "CullIntent"),
        .testTarget(name: "CullIntentTests", dependencies: ["CullIntent"]),

        // Time + feature-print burst clustering. Pure logic over dates and float vectors.
        .target(name: "BurstClustering"),
        .testTarget(name: "BurstClusteringTests", dependencies: ["BurstClustering"]),

        // Priority-queue scheduler: current > next > prev > prefetch.
        .target(name: "RequestScheduling"),
        .testTarget(name: "RequestSchedulingTests", dependencies: ["RequestScheduling"]),

        // Index records + GRDB store + intent-log persistence. Source of truth for the UI.
        .target(
            name: "VampireIndex",
            dependencies: [
                "CullIntent",
                "SonyMakerNotes",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "VampireIndexTests", dependencies: ["VampireIndex"]),

        // PTP/IP protocol codec (Picture Transfer Protocol over IP): packet
        // framing + PTP operation/response encode-decode. Pure byte logic,
        // unit-tested without a camera. The live transport (sockets, Wi-Fi
        // join) lives in the app and drives this codec.
        .target(name: "PTP"),
        .testTarget(name: "PTPTests", dependencies: ["PTP"]),
    ]
)
