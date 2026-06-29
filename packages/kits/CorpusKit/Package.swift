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
        // SubstrateLib: MerkleHash.leaf for the ContentHashProvider callback
        // that HashingRowStore invokes on every chunk insert (ADR-017 §16).
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + ADR-017 §19.
        .package(path: "../../libs/SubstrateLib"),
        // SubstrateKernel: float-vector ops (l2Norm, l2Normalize, dot,
        // cosine) now live here as the canonical conformance-gated
        // implementations. CorpusKitProviders consumes FloatVecOps;
        // higher kits must call the substrate, not inline their own math.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + arch mandate §4.
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/EngramLib"),
        .package(path: "../../libs/EideticLib"),
        // LatticeLib: FDC runtime (FDC.encode) and FDCFrame parent/ancestor
        // derivation consumed by FDCProvider in CorpusKitProviders.
        // Transitive dependency of EideticLib; declared explicitly here so
        // CorpusKitProviders can import LatticeLib directly.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(path: "../../libs/LatticeLib"),
        // IntellectusLib: zero-dependency telemetry leaf. Added for P2
        // self-report coverage (cp-corpuskit-report). When monitoring is
        // disabled (default), the report call is a single Atomic<Bool> load.
        .package(path: "../../libs/IntellectusLib"),
        .package(path: "../PersistenceKit"),
        .package(path: "../ConvergenceKit"),
        .package(path: "../VectorKit"),
        // QueueKit: CorpusKit owns its own ingest queue + drain worker pool, so
        // it mounts a QueueKit-backed encode queue and drains it directly — the
        // SDK-standalone ingest pipeline (a Corpus queues, drains, and encodes
        // itself with no GeniusLocusKit). QueueKit is a low-level primitive
        // (SubstrateTypes + PersistenceKit + IntellectusLib); CorpusKit →
        // QueueKit is downstream→upstream, no inversion.
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 (in-repo kit
        // dependency required by the encode-pipeline relocation into CorpusKit).
        .package(path: "../QueueKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CorpusKit",
            dependencies: [
                "SubstrateTypes", "SubstrateLib", "SubstrateML",
                "EngramLib",
                .product(name: "EideticLib", package: "EideticLib"),
                // IntellectusLib for self-report telemetry (cp-corpuskit-report).
                // Off by default; single Atomic<Bool> load on the disabled path.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                // PersistenceKitInMemory backs the Corpus ingest queue with a
                // transient in-memory backend (no estate file directory; works
                // for in-memory corpora). Mirrors the substrate the standing-
                // signal scheduler queue uses.
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitSQLite: CorpusKit's mountIngestQueue opens the shared
                // encrypted queue.sqlite sibling via SQLiteStorage(configuration:). This
                // is the same encrypted SQLite the estate itself uses — queueSibling
                // derives the sibling config (path + encryption key) so the queue.sqlite
                // is never plaintext beside a plaintext estate (ADR-021 Decision 7 / T4).
                // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                "VectorKit",
                // QueueKit backs the Corpus-owned ingest queue + drain worker
                // pool (the SDK-standalone encode pipeline). See Package
                // dependency note above.
                .product(name: "QueueKit", package: "QueueKit"),
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
                // FDCProvider: text → FDC code via LatticeLib's FDC runtime
                // (FDC.encode). Ancestor chain via FDC.ancestors(of:), the
                // runtime façade over FDCFrame.ancestors(of:). FDC math lives
                // in LatticeLib — not reimplemented in CorpusKitProviders.
                // Authority: ADR-010 Decision B (FDC co-classification signal).
                .product(name: "LatticeLib", package: "LatticeLib"),
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
                .product(name: "SubstrateLib", package: "SubstrateLib"),
                // IntellectusLib is required by CorpusKitTelemetryTests, which
                // install capturing sinks and toggle the enabled flag.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                // LatticeLib is required by FdcProviderTests, which test
                // FDC.ancestors(of:) — the runtime façade used by FDCProvider
                // for the ancestor chain (Gate 2 compliance verification).
                .product(name: "LatticeLib", package: "LatticeLib"),
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
