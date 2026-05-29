// swift-tools-version:6.0
//
// Package.swift — SubstrateLib
//
// SubstrateLib is the math foundation of the GeniusLocus substrate.
// It holds the four-block 256-bit fingerprint construction, the G-Set
// CRDT audit log primitives under HLC ordering, the matrix tier
// kernels with learned dispatch across NEON / BNNS / Metal / SIMD,
// and the federation primitives (pairing handshake, tier-ascending
// query, hyperplane family).
//
// The mathematics here is conformance-gated. Every backend produces
// bit-identical output to the scalar reference across the four
// conformance cells. See Tests/SubstrateLibConformanceTests/ for
// the gate fixtures.
//
// SubstrateLib was promoted from
// docs/engineering/substrate_reference/GeniusLocusReference/
// on 2026-05-19 per DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md.
// The reference implementation continues to exist as a checked-in
// artifact for cookbook cross-reference; SubstrateLib is the
// published product surface that downstream kits consume.

import PackageDescription

let package = Package(
    name: "SubstrateLib",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "SubstrateLib",
            targets: ["SubstrateLib"]
        ),
    ],
    dependencies: [
        // Phase 6 (decision 2026-05-28 §6.6): migrating types into
        // SubstrateTypes one leaf at a time. SubstrateLib remains
        // the published surface and re-exports SubstrateTypes for
        // downstream consumers (see SubstrateLibExports.swift).
        .package(path: "../SubstrateTypes"),
        // Phase 6.9b (decision 2026-05-28 §6): kernel layer
        // (PortableKernel + hardware backends) migrated to
        // SubstrateKernel.
        .package(path: "../SubstrateKernel"),
        // Phase 6.9c (decision 2026-05-28 §6): ML algorithms
        // migrated to SubstrateML.
        .package(path: "../SubstrateML"),
    ],
    targets: [
        .target(
            name: "SubstrateLib",
            dependencies: ["SubstrateTypes", "SubstrateKernel", "SubstrateML"],
            path: "Sources/SubstrateLib"
        ),
        .testTarget(
            name: "SubstrateLibTests",
            dependencies: ["SubstrateLib"],
            path: "Tests/SubstrateLibTests"
        ),
        .testTarget(
            name: "SubstrateLibConformanceTests",
            dependencies: ["SubstrateLib"],
            path: "Tests/SubstrateLibConformanceTests"
        ),
    ]
)
