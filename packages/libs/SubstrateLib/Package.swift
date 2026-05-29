// swift-tools-version:6.0
//
// Package.swift — SubstrateLib
//
// SubstrateLib is the orchestration layer of the four-package substrate
// split (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR addendum 2026-05-29). It
// owns the nine-verb mechanics and the row-state automaton — the control
// surface that composes the three sub-packages — plus the AuditGate write
// gate. The value types live in SubstrateTypes, the hardware-dispatched
// kernels in SubstrateKernel, and the cold-path / ML algorithms in
// SubstrateML; SubstrateLib depends on all three and no longer re-exports
// them (the @_exported shim was removed when the symbol tail relocated).
//
// The mathematics across the four packages is conformance-gated. Every
// backend produces bit-identical output to the scalar reference. See
// Tests/SubstrateLibConformanceTests/ for the gate fixtures.
//
// SubstrateLib was promoted from
// docs/engineering/substrate_reference/GeniusLocusReference/
// on 2026-05-19 per DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md.

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
        // The orchestration layer composes all three sub-packages:
        // value types (SubstrateTypes), hardware kernels
        // (SubstrateKernel — AuditGate's bit_field/sha256), and the
        // cold-path / ML algorithms (SubstrateML).
        .package(path: "../SubstrateTypes"),
        .package(path: "../SubstrateKernel"),
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
            dependencies: ["SubstrateLib", "SubstrateTypes", "SubstrateKernel", "SubstrateML"],
            path: "Tests/SubstrateLibTests"
        ),
        .testTarget(
            name: "SubstrateLibConformanceTests",
            dependencies: ["SubstrateLib", "SubstrateTypes", "SubstrateKernel", "SubstrateML"],
            path: "Tests/SubstrateLibConformanceTests"
        ),
    ]
)
