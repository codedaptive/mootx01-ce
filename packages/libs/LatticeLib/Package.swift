// swift-tools-version: 6.0
//
// Package.swift — LatticeLib
//
// LatticeLib is the lattice/classification library: the lattice-anchor
// spine (StableKey, CollapseRule) and — as the FDC migration proceeds —
// the FDC classification engine and the shared text primitives. It is a
// library, not a kit; downstream consumers (EideticLib, NeuronKit) import
// it. It imports no substrate kit.
//
// FDC migration note (see docs/_internal/FDC_MIGRATION_PLAN_2026-06-01.md):
// this package move is Phase A step 1 of the FDC migration (the kit→lib
// rename). The MDCC machinery (Assembler, Canon, reserved ranges,
// mdcc-build) is still present and is removed once the runtime cuts over
// to FDC (Phase A step 2, after Phase B).

import PackageDescription

let package = Package(
    name: "LatticeLib",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
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
        // The MDCC production-canon build. Retained until the runtime FDC
        // cutover (plan Phase A step 2); then removed with the rest of the
        // MDCC machinery.
        .executableTarget(
            name: "mdcc-build",
            dependencies: ["LatticeLib"]
        ),
        .testTarget(
            name: "LatticeLibTests",
            dependencies: ["LatticeLib", "mdcc-build"]
        ),
    ]
)
