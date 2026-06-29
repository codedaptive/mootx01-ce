// swift-tools-version:6.2
//
// Package.swift — SubstrateKernel
//
// SubstrateKernel is layer 2 of the four-package substrate split
// (I-30, cookbook v1.0 §20). Bandwidth-bound bit operations plus the
// content/seal hashing and bitmap-field primitives.
//
// What lives here (Tier 1 of HARNESS_REFERENCE §2.1):
//   SimHash family
//   Fingerprint256 distance / OR / AND / XOR / prototype ops
//   HammingNN top-K (bounded max-heap, cookbook §17.6)
//   The combinators layer: zip4 / reduce4 / map4 / popcount over
//     Fingerprint256
//   PortableKernel backends: SIMD (`import simd`), NEON (direct ARM
//     intrinsics), and Metal (GPU compute)
//   BitField (bitmap field extraction / masked-equals)
//   SHA-256 content-ID and seal computation (the I-27 integrity
//                                            triangle's binding leg)
//
// What does NOT live here:
//   Pure types (those are in SubstrateTypes — incl. HLC + HLCGenerator)
//   Learning, graph algorithms, matrix updates (those are in
//   SubstrateML)
//   The AuditGate write gate (it validates against RowStateAutomaton,
//   so it lives in SubstrateLib, the orchestration layer; it *consumes*
//   this package's BitField + SHA256). See the 2026-05-29 addendum.
//
// Consumers that depend on this package:
//   Hot-path consumers — LocusKit, CorpusKit, GeniusLocusKit, EngramLib,
//   and SubstrateLib (its AuditGate consumes BitField + SHA256).
//

import PackageDescription

let package = Package(
    name: "SubstrateKernel",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "SubstrateKernel",
            targets: ["SubstrateKernel"]
        ),
    ],
    dependencies: [
        .package(path: "../SubstrateTypes"),
        // IntellectusLib is the substrate's zero-dep telemetry leaf.
        // Adding it here lets kernelForCurrentPlatform() emit the
        // backend_selected metric at the selection site.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 +
        //            MANAGER_1.0_PLAN.md §2 (SubstrateLib bullet).
        // Layering: IntellectusLib has zero repo deps; this is strictly
        // downstream→upstream, no cycle.
        .package(path: "../IntellectusLib"),
    ],
    targets: [
        .target(
            name: "SubstrateKernel",
            dependencies: ["SubstrateTypes", "IntellectusLib"],
            path: "Sources/SubstrateKernel"
        ),
        .testTarget(
            name: "SubstrateKernelTests",
            dependencies: ["SubstrateKernel", "SubstrateTypes", "IntellectusLib"],
            path: "Tests/SubstrateKernelTests"
        ),
    ]
)
