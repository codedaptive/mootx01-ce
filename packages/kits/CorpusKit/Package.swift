// swift-tools-version:6.2
//
// CorpusKit -- retrieval-augmented generation storage and retrieval.
//
// Two targets:
//   CorpusKit           -- core surface (chunkers, BM25, bundle store,
//                       tokenizer protocols, sync manifest)
//   CorpusKitProviders  -- text embedding providers (MiniLM, mpnet,
//                       EmbeddingGemma) and their tokenizers
//
// Providers split out so the core kit stays small. Consumers that
// only need bundle storage and BM25 do not pull in CoreML models.
//
// IntellectusLib dependency added per
// DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 (P2 self-report telemetry
// coverage, cp-corpuskit-report). IntellectusLib is a zero-dependency
// leaf lib; layering is not inverted.

import PackageDescription

let package = Package(
    name: "CorpusKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "CorpusKit", targets: ["CorpusKit"]),
        .library(name: "CorpusKitProviders", targets: ["CorpusKitProviders"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateTypes"),
        // SubstrateKernel: float-vector ops (l2Norm, l2Normalize, dot,
        // cosine) now live here as the canonical conformance-gated
        // implementations. CorpusKitProviders consumes FloatVecOps;
        // higher kits must call the substrate, not inline their own math.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + arch mandate §4.
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/EngramLib"),
        .package(path: "../../libs/EideticLib"),
        // IntellectusLib: zero-dependency telemetry leaf. Added for P2
        // self-report coverage (cp-corpuskit-report). When monitoring is
        // disabled (default), the report call is a single Atomic<Bool> load.
        .package(path: "../../libs/IntellectusLib"),
        .package(path: "../PersistenceKit"),
        .package(path: "../ConvergenceKit"),
        .package(path: "../VectorKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CorpusKit",
            dependencies: [
                "SubstrateTypes", "SubstrateML",
                "EngramLib",
                .product(name: "EideticLib", package: "EideticLib"),
                // IntellectusLib for self-report telemetry (cp-corpuskit-report).
                // Off by default; single Atomic<Bool> load on the disabled path.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                "VectorKit",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CorpusKit"
        ),
        .target(
            name: "CorpusKitProviders",
            dependencies: [
                "CorpusKit",
                "SubstrateTypes",
                // SubstrateKernel supplies the canonical float-vector ops
                // (FloatVecOps.l2Normalize, dot, cosine) that providers
                // must call instead of inlining their own implementations.
                "SubstrateKernel",
                "SubstrateML",
                "EngramLib",
                "VectorKit",
            ],
            path: "Sources/CorpusKitProviders"
        ),
        .testTarget(
            name: "CorpusKitTests",
            dependencies: [
                "CorpusKit",
                "CorpusKitProviders",
                // VectorKit supplies the EmbeddingProvider protocol the
                // embedding-provider conformance gate references directly
                // (EmbeddingProviderConformanceTests, B2-5 parity gate).
                "VectorKit",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitSQLite is required by the SQLite-backed chunk HLC
                // round-trip test (ChunkHLCRoundTripTests), which exercises the
                // unpackHLC fix through BundleStore's actual SQLite storage path.
                // Also required by InvertedIndexStore tests (Lane D): the store's
                // persistence contract requires a real SQLite backend, not InMemory.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                // IntellectusLib is required by CorpusKitTelemetryTests, which
                // install capturing sinks and toggle the enabled flag.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Tests/CorpusKitTests",
            resources: [
                // Shared cross-language canonical vectors (BM25 bit-identity gate,
                // finding W1). The Rust leg reads the SAME file at
                // rust/tests/bm25_conformance_test.rs via include_bytes! up the tree.
                .copy("../SharedVectors"),
            ]
        ),
    ]
)
