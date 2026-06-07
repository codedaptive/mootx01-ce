// swift-tools-version: 6.2
//
// Package.swift — LatticeLib
//
// LatticeLib is the lattice/classification library: the FDC
// (Frame-Directed Classification) engine and the shared text
// primitives. It is a library, not a kit; downstream consumers
// (EideticLib, NeuronKit) import it. It imports no substrate kit.

import PackageDescription

let package = Package(
    name: "LatticeLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "LatticeLib",
            targets: ["LatticeLib"]
        ),
    ],
    dependencies: [
        // SubstrateML provides EigenvalueCentrality (LexRank) and FloatSimHash
        // (signature fingerprint). Substrate math is the right home for these.
        .package(path: "../SubstrateML"),
    ],
    targets: [
        .target(
            name: "LatticeLib",
            dependencies: [
                .product(name: "SubstrateML", package: "SubstrateML"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "LatticeLibTests",
            dependencies: ["LatticeLib"]
        ),
    ]
)
