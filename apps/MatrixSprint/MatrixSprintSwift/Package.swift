// swift-tools-version:6.0
//
// MatrixSprint — Swift port
//
// Two executables:
//   stress-test  — sweeps every (op, batch_size, mode) cell across
//                  all kernel backends, producing structured JSON
//                  for hardware comparison
//   topk-bench   — sweeps K and N across `hamming_top_k`
//
// Depends on the conformance harness library for shared
// infrastructure (kernel_registry, Stats, JSON output schema).
// The harness library lives in
// docs/validation/substrate_math_performance/test-harness/swift/,
// where the conformance bins (gen-vectors, validate-vectors) also
// live. This split keeps bit-identity tests separate from speed
// tests but shares the registry of available backends.

import PackageDescription

let package = Package(
    name: "MatrixSprint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stress-test", targets: ["StressTest"]),
        .executable(name: "topk-bench",  targets: ["TopKBench"]),
        .executable(name: "ml-bench",    targets: ["MLBench"]),
    ],
    dependencies: [
        .package(path: "../../../docs/validation/substrate_math_performance/test-harness/swift"),
        .package(path: "../../../docs/validation/substrate_math_performance/GeniusLocusReference"),
        .package(path: "../../../packages/libs/SubstrateTypes"),
        .package(path: "../../../packages/libs/SubstrateML"),
    ],
    targets: [
        .executableTarget(
            name: "StressTest",
            dependencies: [
                .product(name: "Harness", package: "swift"),
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
            ]
        ),
        .executableTarget(
            name: "TopKBench",
            dependencies: [
                .product(name: "Harness", package: "swift"),
                .product(name: "GeniusLocusReference", package: "GeniusLocusReference"),
            ]
        ),
        .executableTarget(
            name: "MLBench",
            dependencies: [
                .product(name: "Harness", package: "swift"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateML", package: "SubstrateML"),
            ]
        ),
    ]
)
