// swift-tools-version:6.0
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
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gen-vectors",      targets: ["GenVectors"]),
        .executable(name: "validate-vectors", targets: ["ValidateVectors"]),
        .library(name: "Harness", targets: ["Harness"]),
    ],
    dependencies: [
        .package(path: "../../GeniusLocusReference"),
    ],
    targets: [
        .executableTarget(
            name: "GenVectors",
            dependencies: [
                "Harness",
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
            ]
        ),
        .executableTarget(
            name: "ValidateVectors",
            dependencies: [
                "Harness",
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
            ]
        ),
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
            ]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"]
        ),
    ]
)
