// swift-tools-version:6.0
//
// Package.swift — SubstrateML
//
// SubstrateML is layer 3 of the four-package substrate split
// (I-30, cookbook v1.0 §20). Cold-path and dreaming-driven
// algorithms — learning, graph algorithms, projection.
//
// What lives here (Tier 2 + Tier 3 of HARNESS_REFERENCE §2.2-§2.3):
//   MatrixDecay (lazy multiplicative half-life)
//   MomentSummary (OR-reduce over active rows in a window)
//   BradleyTerry (online pairwise comparison gradient)
//   Anomaly (z-score from cohort centroid)
//   InfoTheory (entropy / MI / KL)
//   TemporalCompression (cascading OR-reduce, retention rollups)
//   PartialStateRecall
//   FFT (rhythm analysis)
//   NMF (alternating least squares on O)
//   EigenvalueCentrality (power iteration with Perron-Frobenius shift)
//   AuditLogFold (project current / as-of state from event sequence)
//   TierContribution (re-fingerprint under shared seeds + OR-reduce)
//   PairingHandshake (generate-and-exchange shared hyperplane family)
//
// What does NOT live here:
//   Pure types (SubstrateTypes)
//   Hot-path bit ops, AuditGate, HLCGenerator, SHA-256 (SubstrateKernel)
//
// Consumers that depend on this package:
//   LocusKit (audit log fold for recall, anomaly), CognitionKit
//   (the §11 primitive suite), GeniusLocusKit (federation),
//   dreaming-daemon code paths.
//

import PackageDescription

let package = Package(
    name: "SubstrateML",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "SubstrateML",
            targets: ["SubstrateML"]
        ),
    ],
    dependencies: [
        .package(path: "../SubstrateTypes"),
        .package(path: "../SubstrateKernel"),
    ],
    targets: [
        .target(
            name: "SubstrateML",
            dependencies: ["SubstrateTypes", "SubstrateKernel"],
            path: "Sources/SubstrateML"
        ),
        .testTarget(
            name: "SubstrateMLTests",
            dependencies: ["SubstrateML", "SubstrateTypes", "SubstrateKernel"],
            path: "Tests/SubstrateMLTests"
        ),
    ]
)
