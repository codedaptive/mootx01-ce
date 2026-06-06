// swift-tools-version:6.2
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
        .macOS(.v26),
        .iOS(.v26),
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
        // IntellectusLib is the zero-dep telemetry leaf. Adding it here
        // lets the five VizGraph algorithms emit community.assignment,
        // centrality.score, nmf.factor, anomaly.flag, and edge.decayed_weight
        // signals when monitoring is enabled.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        // Layering: IntellectusLib has zero repo deps (std only);
        // SubstrateML is downstream — no cycle introduced.
        .package(path: "../IntellectusLib"),
    ],
    targets: [
        .target(
            name: "SubstrateML",
            dependencies: ["SubstrateTypes", "SubstrateKernel", "IntellectusLib"],
            path: "Sources/SubstrateML"
        ),
        .testTarget(
            name: "SubstrateMLTests",
            dependencies: ["SubstrateML", "SubstrateTypes", "SubstrateKernel", "IntellectusLib"],
            path: "Tests/SubstrateMLTests"
        ),
    ]
)
