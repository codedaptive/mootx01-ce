// swift-tools-version:6.2
//
// Package.swift — SubstrateML
//
// SubstrateML is layer 3 of the four-package substrate split
// (I-30, cookbook v1.0 §20). Cold-path and dreaming-driven
// algorithms — learning, graph algorithms, projection.
//
// What lives here (selected; see Sources/SubstrateML/ for the full list):
//   MatrixDecay, MomentSummary, BradleyTerry, Anomaly, InfoTheory,
//   TemporalCompression, PartialStateRecall, FFT, NMF,
//   EigenvalueCentrality, AuditLogFold, TierContribution,
//   PairingHandshake, ActionOutcomeMatrix, AprioriMining,
//   AssociationRuleMining, ConceptImplications, DPORReduction,
//   DeltaFeatureExtractor, DistillationPipeline, DistillationScorer,
//   FeatureExtractors, FloatSimHash, FormalConceptAnalysis, JacobiSVD,
//   LLMCalibrationCurve, LatticeDistance, RandomWalks, RowAttributeView,
//   Sampling, ShingleSimilarity, TemporalCausalityFold,
//   TierAscendingQuery, TypedDecayWeighting, VizGraphSignals
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
