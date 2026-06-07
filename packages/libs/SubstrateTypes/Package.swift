// swift-tools-version:6.2
//
// Package.swift — SubstrateTypes
//
// SubstrateTypes is layer 1 of the four-package substrate split
// (I-30, cookbook v1.0 §20). Pure data types, zero compute, zero
// transcendentals, zero I/O.
//
// What lives here:
//   Fingerprint256 (struct + wire encoding only)
//   HLC (struct + ordering + wire encoding only; generator is in
//        SubstrateKernel)
//   LatticeAnchor, Row, RowLite, NounType, RowStateValue
//   AuditEvent (struct shape only)
//   MatrixF / MatrixC / MatrixO / MatrixT (storage and indexing,
//                                          no learning)
//   BlockMask, RowBitmaps, BitVector216 (layout constants)
//   TimeRange
//   Enums: MutationKind, PairingScope, GeneratedByClass, etc.
//
// What does NOT live here:
//   Any algorithm that does compute (those go to SubstrateKernel or
//   SubstrateML).
//
// Consumers that depend ONLY on this package:
//   ConvergenceKit (serializes rows to CloudKit; needs shape only)
//   Future kits that just need to speak substrate-shape.
//
// per the six-phase plan in
// docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md.
// As of 2026-05-29 the four-package split is complete: SubstrateLib is
// the orchestration layer over Types/Kernel/ML and no longer re-exports
// them. Consumers depend on this package directly.

import PackageDescription

let package = Package(
    name: "SubstrateTypes",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "SubstrateTypes",
            targets: ["SubstrateTypes"]
        ),
    ],
    targets: [
        .target(
            name: "SubstrateTypes",
            path: "Sources/SubstrateTypes"
        ),
        .testTarget(
            name: "SubstrateTypesTests",
            dependencies: ["SubstrateTypes"],
            path: "Tests/SubstrateTypesTests"
        ),
    ]
)
