// swift-tools-version:6.0
//
// EngramLib — product-facing Swift library for 256-bit engram
// similarity and retrieval. Wraps SubstrateLib's kernel layer
// behind a stable, minimal API. Consumers do not see kernel
// selection, dispatcher logic, or substrate internals.
//
// Refactored 2026-05-19 to depend on the promoted SubstrateLib
// package instead of the upstream-staging GeniusLocusReference.
// Mission 4 of the eleven-kit graph refactor.

import PackageDescription

let package = Package(
    name: "EngramLib",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "EngramLib",
            targets: ["EngramLib"]
        ),
    ],
    dependencies: [
        .package(path: "../SubstrateLib"),
        .package(path: "../SubstrateTypes"),
    ],
    targets: [
        .target(
            name: "EngramLib",
            dependencies: ["SubstrateLib", "SubstrateTypes"]
        ),
        .testTarget(
            name: "EngramLibTests",
            dependencies: ["EngramLib"]
        ),
    ]
)
