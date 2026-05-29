// swift-tools-version: 6.0
//
// Package.swift — LatticeKit
//
// MDCC is the Moot Decimal Classification Codes — MOOTx01's original
// decimal classification system. The notation is Dewey-like (a code's
// structure encodes where a concept sits in the tree) but the system
// is original work, not DDC. Built clean-room from CC0 (Wikidata) and
// US-government public-domain sources (LCC, LCSH, LC name authority).
//
// LatticeKit is a peer of the MOOTx01 substrate kits, not a member of
// them. Downstream consumers (EideticLib, NeuronKit) import LatticeKit
// to resolve terms to MDCC codes. LatticeKit imports no substrate kit.
//
// Three layers ship in v1:
//   1. The notation spec — top-of-tree spine, single-parent collapse
//      rule, stable-keying scheme, reserved ranges. Authored.
//   2. The assembler — deterministic build over CC0 graph input,
//      producing stable codes across reruns.
//   3. The v1 canon plus fast-codes and slow-docs channels.

import PackageDescription

let package = Package(
    name: "LatticeKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "LatticeKit",
            targets: ["LatticeKit"]
        ),
    ],
    targets: [
        .target(
            name: "LatticeKit",
            resources: [
                .process("Resources"),
            ]
        ),
        // The reproducible production-canon build. Runs the pipeline
        // end to end (load seed, fetch edges, assemble, write artifacts)
        // and produces the bundled canon from CC0 data. No new external
        // dependencies — only the LatticeKit library.
        .executableTarget(
            name: "mdcc-build",
            dependencies: ["LatticeKit"]
        ),
        .testTarget(
            name: "LatticeKitTests",
            // Depends on mdcc-build so the executable is compiled and
            // type-checked as part of `swift test`; the integration
            // tests drive the library primitives directly.
            dependencies: ["LatticeKit", "mdcc-build"]
        ),
    ]
)
