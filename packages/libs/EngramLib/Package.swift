// swift-tools-version:6.2
//
// EngramLib — product-facing Swift library for 256-bit engram
// similarity and retrieval. Wraps SubstrateLib's kernel layer
// behind a stable, minimal API. Consumers do not see kernel
// selection, dispatcher logic, or substrate internals.
//
// Refactored 2026-05-19 to depend on the promoted SubstrateLib
// package instead of the upstream-staging GeniusLocusReference.

import PackageDescription

let package = Package(
    name: "EngramLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "EngramLib",
            targets: ["EngramLib"]
        ),
    ],
    dependencies: [
        .package(path: "../SubstrateTypes"),
        .package(path: "../SubstrateKernel"),
    ],
    targets: [
        .target(
            name: "EngramLib",
            dependencies: ["SubstrateTypes", "SubstrateKernel"]
        ),
        .testTarget(
            name: "EngramLibTests",
            dependencies: ["EngramLib"]
        ),
    ]
)
