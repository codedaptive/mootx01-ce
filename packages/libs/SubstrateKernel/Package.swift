// swift-tools-version:6.0
//
// Package.swift — SubstrateKernel
//
// SubstrateKernel is layer 2 of the four-package substrate split
// (I-30, cookbook v1.0 §20). Bandwidth-bound bit operations plus the
// write-gate and clock-maker primitives.
//
// What lives here (Tier 1 of HARNESS_REFERENCE §2.1):
//   SimHash family
//   Fingerprint256 distance / OR / AND / XOR / prototype ops
//   HammingNN top-K (branchless ladder, cookbook §17.6)
//   The combinators layer: zip4 / reduce4 / map4 / popcount over
//     Fingerprint256
//   SimdKernel (Swift NEON via `import simd`)
//   AuditGate (the write gate; admits FieldWrite sets, validates
//              against VocabularyValidator; the gate's prior == nil
//              branch is the capture path, I-26)
//   HLCGenerator (open / tick / takeover, I-28)
//   SHA-256 content-ID and seal computation (the I-27 integrity
//                                            triangle's binding leg)
//
// What does NOT live here:
//   Pure types (those are in SubstrateTypes)
//   Learning, graph algorithms, matrix updates (those are in
//   SubstrateML)
//
// Consumers that depend on this package:
//   All hot-path consumers — LocusKit, RagKit, CognitionKit,
//   GeniusLocusKit, PersistenceKit (for AuditGate enforcement).
//

import PackageDescription

let package = Package(
    name: "SubstrateKernel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "SubstrateKernel",
            targets: ["SubstrateKernel"]
        ),
    ],
    dependencies: [
        .package(path: "../SubstrateTypes"),
    ],
    targets: [
        .target(
            name: "SubstrateKernel",
            dependencies: ["SubstrateTypes"],
            path: "Sources/SubstrateKernel"
        ),
        .testTarget(
            name: "SubstrateKernelTests",
            dependencies: ["SubstrateKernel", "SubstrateTypes"],
            path: "Tests/SubstrateKernelTests"
        ),
    ]
)
