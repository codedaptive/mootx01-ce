// swift-tools-version:6.0
//
// Package.swift — SubstrateTypes
//
// SubstrateTypes is layer 1 of the three-package SubstrateLib split
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
// Build status during refactor: skeleton. Real type migrations land
// per the six-phase plan in
// docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md.
// The legacy SubstrateLib remains the published surface until the
// three-package set is fully wired and conformance-gated.

import PackageDescription

let package = Package(
    name: "SubstrateTypes",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
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
