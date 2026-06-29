// swift-tools-version:6.2
//
// Swift package for the GeniusLocus reference test harness.
//
// Three executables:
//   gen-vectors       -  generates test-vector JSON files from the
//                      Swift scalar reference implementations
//   validate-vectors  -  validates an existing JSON file against
//                      the Swift scalar reference
//   stress-test       -  measures per-(op, batch_size, mode)
//                      latency for the batched kernel ops;
//                      produces structured JSON for the
//                      learned dispatcher (Phase 1 of
//                      DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17)
//
// Path 2 wire-up: the harness now depends on the real
// `GeniusLocusReference` package at
// `substrate_reference/GeniusLocusReference/`. Harness primitives that
// previously embedded byte-identical stubs (e.g. SimHash) now
// delegate to the canonical Swift port. CRCs against existing
// vector files must be regenerated after this wire-up.

import PackageDescription

let package = Package(
    name: "GeniusLocusTestHarness",
    // macOS 26 required by SubstrateML and its transitive deps (SubstrateTypes,
    // SubstrateKernel, IntellectusLib). Bumped from v14 when SubstrateML was
    // added to validate association_rule_mining and formal_concept_analysis vectors.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "gen-vectors",      targets: ["GenVectors"]),
        .executable(name: "validate-vectors", targets: ["ValidateVectors"]),
        .executable(name: "nt-p0-bakeoff",    targets: ["NTP0Bakeoff"]),
        .library(name: "Harness", targets: ["Harness"]),
    ],
    dependencies: [
        .package(path: "../../GeniusLocusReference"),
        .package(path: "../../../../../packages/libs/SubstrateTypes"),
        .package(path: "../../../../../packages/libs/SubstrateKernel"),
        // SubstrateML wired in so the Swift harness can validate
        // association_rule_mining and formal_concept_analysis vectors using
        // the production Swift implementations, matching the Rust harness.
        // SubstrateTypes, SubstrateKernel, and IntellectusLib are brought
        // in transitively by SubstrateML.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(path: "../../../../../packages/libs/SubstrateML"),
    ],
    targets: [
        .executableTarget(
            name: "GenVectors",
            dependencies: [
                "Harness",
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateML", package: "SubstrateML"),
            ]
        ),
        .executableTarget(
            name: "ValidateVectors",
            dependencies: [
                "Harness",
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
                .product(name: "SubstrateML", package: "SubstrateML"),
            ]
        ),
        .executableTarget(
            name: "NTP0Bakeoff",
            dependencies: [
                "PlatformCryptoCandidate",
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
            ]
        ),
        .target(
            name: "PlatformCryptoCandidate",
            dependencies: []
        ),
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
                .product(name: "SubstrateML", package: "SubstrateML"),
            ]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"]
        ),
    ]
)
