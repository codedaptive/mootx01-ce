// swift-tools-version:6.2
//
// CorpusKit -- retrieval-augmented generation storage and retrieval.
//
// Two targets:
//   CorpusKit           -- canonical-content engine, BM25/vector retrieval,
//                       optional standalone passages, tokenizer protocols,
//                       plus the legacy standalone compatibility surface
//   CorpusKitProviders  -- text embedding providers (MiniLM and, when opted
//                       in, the dense families and Apple encoders) and their
//                       tokenizers
//
// Providers split out so the core kit stays small. Consumers that
// only need bundle storage and BM25 do not pull in CoreML models.
//
// IntellectusLib dependency added per
// in-repository dependency direction (P2 self-report telemetry
// coverage, cp-corpuskit-report). IntellectusLib is a zero-dependency
// leaf lib; layering is not inverted.
//
// Compile-time switches (CorpusKitProviders target):
//
//   DenseFamilies  (Swift trait → MOOTX01_DENSE_FAMILIES, Rust feature dense-families)
//       Compiles LSA, NMF, PPMI, FDC, MPNet, and EmbeddingGemma providers.
//       OFF by default: measurement (plan 70BC55F3, 2026-09-05) showed these
//       four families add cost without beating BM25+RI on two corpora.
//       RI stays always-on because its binary fingerprint feeds dreaming,
//       contradiction, and consolidation. Enable with:
//           swift test --traits DenseFamilies
//           cargo test --features dense-families
//
//   AppleEncoders  (Swift trait → APPLE_ENCODERS; Swift-only, no Rust twin)
//       Compiles NLContextualEmbeddingProvider, NLEmbeddingProvider,
//       AppleNLProvider, and NeuralEmbedProvider. OFF by default.
//       These providers measured at half the signal of a retrieval-trained
//       model; held for iOS and Apple cloud compute (v1.2). Enable with:
//           swift test --traits AppleEncoders
//
//   WholeRecordDense  (Swift trait → MOOTX01_WHOLE_RECORD_DENSE, Rust feature
//                      whole-record-dense)
//       Compiles the whole-record dense float engine: the float row write at
//       ingest (vectorIndex 1), the per-signal float query surface
//       (CorpusKitWholeRecordDense target) and their tests. OFF by default
//       (ruling 2026-09-07): the span stage is the one dense provider in the
//       product; the whole-record float lane was the audition baseline and
//       cut lexical gold at fusion. DenseFamilies enables it because the
//       dense families exist only as whole-record float signals. Enable with:
//           swift test --traits WholeRecordDense
//           cargo test --features whole-record-dense

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
        // The whole-record dense sidecar. Empty unless the WholeRecordDense
        // trait is on; the default product graph never links it.
        .library(name: "CorpusKitWholeRecordDense", targets: ["CorpusKitWholeRecordDense"]),
    ],
    traits: [
        .trait(
            name: "StandalonePassages",
            description: "Compile optional standalone token-window passage indexing. GeniusLocusKit/MOOTx01 intentionally leaves this trait disabled."
        ),
        .trait(
            name: "DenseFamilies",
            description: "Compile LSA, NMF, PPMI, FDC, MPNet, and EmbeddingGemma providers. Off by default (plan 70BC55F3, 2026-09-05): measured cost exceeds benefit vs. BM25+RI on two corpora. Defines MOOTX01_DENSE_FAMILIES; enable with `swift test --traits DenseFamilies`. Enables WholeRecordDense: the families are whole-record float signals.",
            enabledTraits: ["WholeRecordDense"]
        ),
        .trait(
            name: "WholeRecordDense",
            description: "Compile the whole-record dense float engine (float rows at ingest, the CorpusKitWholeRecordDense query surface, their tests). Off by default (ruling 2026-09-07): the span stage is the one dense provider. Defines MOOTX01_WHOLE_RECORD_DENSE; enable with `swift test --traits WholeRecordDense`."
        ),
        // LSA: the LsaProvider, its basis training, its ensemble membership and
        // its tests on a switch of their own (ruling 2026-09-07). DenseFamilies
        // does not enable it and the dark-variant gate does not build it: the
        // family is dark and unproven (`reindex recovers a deliberately-degenerate
        // LSA basis` fails). Enables DenseFamilies, which the provider's shared
        // counts and reduced vocabulary need.
        .trait(
            name: "LSA",
            description: "Compile the LsaProvider, its basis training and its tests. Dark and unproven since 2026-09-07; DenseFamilies does not enable it. Defines MOOTX01_LSA and enables DenseFamilies; enable with `swift test --traits LSA`.",
            enabledTraits: ["DenseFamilies"]
        ),
        .trait(
            name: "AppleEncoders",
            description: "Compile Apple NL embedding providers (NLContextualEmbeddingProvider, NLEmbeddingProvider, AppleNLProvider, NeuralEmbedProvider). Off by default; held for v1.2 iOS and Apple cloud compute. Swift-only. Defines APPLE_ENCODERS; enable with `swift test --traits AppleEncoders`."
        ),
    ],
    dependencies: [
        .package(name: "MootProductIdentity", path: "../../libs/MootProductIdentity"),
        .package(path: "../../libs/SubstrateTypes"),
        // SubstrateLib: MerkleHash.leaf for the ContentHashProvider callback
        // that HashingRowStore invokes on every chunk insert.
        // Authority: in-repository dependency direction + node-tree integrity.
        .package(path: "../../libs/SubstrateLib"),
        // SubstrateKernel: float-vector ops (l2Norm, l2Normalize, dot,
        // cosine) now live here as the canonical conformance-gated
        // implementations. CorpusKitProviders consumes FloatVecOps;
        // higher kits must call the substrate, not inline their own math.
        // Repository-owned dependencies use local package paths.
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/EngramLib"),
        .package(path: "../../libs/EideticLib"),
        // LatticeLib: FDC runtime (FDC.encode) and FDCFrame parent/ancestor
        // derivation consumed by FDCProvider in CorpusKitProviders.
        // Transitive dependency of EideticLib; declared explicitly here so
        // CorpusKitProviders can import LatticeLib directly.
        // Authority: in-repository dependency direction.
        .package(path: "../../libs/LatticeLib"),
        // IntellectusLib: zero-dependency telemetry leaf. Added for P2
        // self-report coverage (cp-corpuskit-report). When monitoring is
        // disabled (default), the report call is a single Atomic<Bool> load.
        .package(path: "../../libs/IntellectusLib"),
        .package(path: "../PersistenceKit"),
        .package(path: "../ConvergenceKit"),
        .package(path: "../SynapseKit"),
        // QueueKit: CorpusKit owns its own ingest queue + drain worker pool, so
        // it mounts a QueueKit-backed encode queue and drains it directly — the
        // SDK-standalone ingest pipeline (a Corpus queues, drains, and encodes
        // itself with no GeniusLocusKit). QueueKit is a low-level primitive
        // (SubstrateTypes + PersistenceKit + IntellectusLib); CorpusKit →
        // QueueKit is downstream→upstream, no inversion.
        // Authority: in-repository dependency direction (in-repo kit
        // dependency required by the encode-pipeline relocation into CorpusKit).
        .package(path: "../QueueKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CorpusKit",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "SubstrateTypes", "SubstrateLib", "SubstrateKernel",
                "SubstrateML",
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
                // is never plaintext beside a plaintext estate.
                // Authority: in-repository dependency direction.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                "SynapseKit",
                // QueueKit backs the Corpus-owned ingest queue + drain worker
                // pool (the SDK-standalone encode pipeline). See Package
                // dependency note above.
                .product(name: "QueueKit", package: "QueueKit"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CorpusKit",
            swiftSettings: [
                .define(
                    "CORPUSKIT_STANDALONE_PASSAGES",
                    .when(traits: ["StandalonePassages"])
                ),
                // WholeRecordDense trait → MOOTX01_WHOLE_RECORD_DENSE: gates the
                // float row write at ingest and the forced-error test seam the
                // sidecar target reads.
                .define("MOOTX01_WHOLE_RECORD_DENSE", .when(traits: ["WholeRecordDense"])),
            ]
        ),
        // The whole-record dense sidecar: the float query surface as `package`
        // extensions of Corpus and CorpusContentEngine plus FloatLaneOutcome.
        // Every file is wrapped in `#if MOOTX01_WHOLE_RECORD_DENSE`, so the
        // target is an empty module when the trait is off.
        .target(
            name: "CorpusKitWholeRecordDense",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "CorpusKit",
                "SynapseKit",
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Sources/CorpusKitWholeRecordDense",
            swiftSettings: [
                .define("MOOTX01_WHOLE_RECORD_DENSE", .when(traits: ["WholeRecordDense"])),
            ]
        ),
        .target(
            name: "CorpusKitProviders",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "CorpusKit",
                "SubstrateTypes",
                // SubstrateKernel supplies the canonical float-vector ops
                // (FloatVecOps.l2Normalize, dot, cosine) that providers
                // must call instead of inlining their own implementations.
                "SubstrateKernel",
                "SubstrateML",
                "EngramLib",
                "SynapseKit",
                // FDCProvider: text → FDC code via LatticeLib's FDC runtime
                // (FDC.encode). Ancestor chain via FDC.ancestors(of:), the
                // runtime façade over FDCFrame.ancestors(of:). FDC math lives
                // in LatticeLib — not reimplemented in CorpusKitProviders.
                // Authority: honest semantic fusion (FDC co-classification signal).
                .product(name: "LatticeLib", package: "LatticeLib"),
            ],
            path: "Sources/CorpusKitProviders",
            swiftSettings: [
                // DenseFamilies trait → MOOTX01_DENSE_FAMILIES: gates NMF/PPMI/
                // FDC/MPNet/EmbeddingGemma providers. Off by default (plan 70BC55F3).
                .define("MOOTX01_DENSE_FAMILIES", .when(traits: ["DenseFamilies"])),
                // LSA trait → MOOTX01_LSA: gates the LsaProvider on its own switch.
                .define("MOOTX01_LSA", .when(traits: ["LSA"])),
                // AppleEncoders trait → APPLE_ENCODERS: gates Apple NL providers.
                // Swift-only; no Rust twin. Off by default (held for v1.2).
                .define("APPLE_ENCODERS", .when(traits: ["AppleEncoders"])),
            ]
        ),
        .testTarget(
            name: "CorpusKitTests",
            dependencies: [
                "CorpusKit",
                "CorpusKitProviders",
                // The DenseFamilies basis tests probe a trained basis through
                // the whole-record float lane; DenseFamilies implies the trait.
                .target(name: "CorpusKitWholeRecordDense", condition: .when(traits: ["WholeRecordDense"])),
                // SynapseKit supplies the EmbeddingProvider protocol the
                // embedding-provider conformance gate references directly
                // (EmbeddingProviderConformanceTests, B2-5 parity gate).
                "SynapseKit",
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
                // Encoder model test fixtures: vocab.txt and a placeholder
                // .mlmodelc directory for ModelDirectoryResolver tests.
                // Copy the model directory directly so it lands at the
                // bundle resource root as "minilm-l6-v2-w60/" — matching
                // the layout the production app uses (models are copied to
                // the app bundle root in project.yml). The resolver's
                // bundleSlot checks <bundle.resourcePath>/minilm-l6-v2-w60/.
                // The real 90 MB .mlmodelc is never committed; the placeholder
                // confirms directory presence without the full binary artifact.
                .copy("../Fixtures/encoder-models/minilm-l6-v2-w60"),
            ],
            swiftSettings: [
                .define(
                    "CORPUSKIT_STANDALONE_PASSAGES",
                    .when(traits: ["StandalonePassages"])
                ),
                // Mirror the provider switches in tests so dense-family and Apple
                // encoder test suites compile only when the matching trait is on.
                .define("MOOTX01_DENSE_FAMILIES", .when(traits: ["DenseFamilies"])),
                .define("MOOTX01_LSA", .when(traits: ["LSA"])),
                .define("APPLE_ENCODERS", .when(traits: ["AppleEncoders"])),
                .define("MOOTX01_WHOLE_RECORD_DENSE", .when(traits: ["WholeRecordDense"])),
            ]
        ),
        // Tests of the whole-record dense engine. Compiled only with the
        // WholeRecordDense trait (every file is wrapped in the define).
        .testTarget(
            name: "CorpusKitWholeRecordDenseTests",
            dependencies: [
                "CorpusKit",
                "CorpusKitProviders",
                "CorpusKitWholeRecordDense",
                "SynapseKit",
                "EngramLib",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Tests/CorpusKitWholeRecordDenseTests",
            swiftSettings: [
                .define("MOOTX01_DENSE_FAMILIES", .when(traits: ["DenseFamilies"])),
                .define("MOOTX01_LSA", .when(traits: ["LSA"])),
                .define("MOOTX01_WHOLE_RECORD_DENSE", .when(traits: ["WholeRecordDense"])),
            ]
        ),
    ]
)
