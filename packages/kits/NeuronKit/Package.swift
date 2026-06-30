// swift-tools-version: 6.2
//
// NeuronKit, the algorithms layer of the MOOTx01 substrate. Hosts
// autonomic functions (the enrichment daemon, dreaming, maintenance,
// standing-signals scheduler, SolverBandit, audit-chain monitor) and
// reasoning functions (hybrid recall, MMR diversification,
// ContextSynthesizer, branch derivation, tournament scoring) per
// NEURONKIT_SPEC_v0.1.md.
//
// First real implementation: the deterministic lattice-anchor
// inference path. NeuronKit composes EideticLib (the standalone
// text-to-anchor utility) and adds substrate-specific concerns:
// the LatticeAnchorInference result shape that records the
// provenance enrichment_status bit transition, the audit-log
// recording, and the standing-signal scheduler integration. The
// linguistic pipeline itself (tokenize, normalize, stem,
// gazetteer-match, classify, resolve) lives in EideticLib.
//
// Per DESIGN_CONSTRAINTS.md C-1, this kit takes NO external ML
// runtime dependencies. Pure Swift source plus the EideticLib
// dependency, whose CC-BY-SA reference data stays on the outside
// of the substrate's compliance boundary by the mere-aggregation
// doctrine.

import PackageDescription

let package = Package(
    name: "NeuronKit",
    platforms: [
        // Aligned with GeniusLocusKit (macOS 15 / iOS 18) so the
        // estate-handle dependency resolves cleanly. NeuronKit had no
        // platform-specific feature use at the prior floor (14 / 17).
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "NeuronKit",
            targets: ["NeuronKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../libs/EideticLib"),
        // LatticeLib supplies Tokenizer.tokenize (UAX #29 word boundaries) and
        // LatticeLib.wordClass(_:tagger:recordNovel:) with .hmm and recordNovel:false,
        // which is the deterministic HMM/Viterbi novel-token tagger whose output is
        // byte-identical Swift↔Rust. The recordNovel:false flag suppresses pool
        // accumulation so memory-drawer content is not leaked to the pool pipeline.
        // HMMFeatureExtractor (Lenses/HMMFeatureExtractor.swift) depends on both.
        // Citation: Distillation.swift §1 design note; fix/ce-hmm-pool-leak.
        .package(path: "../../libs/LatticeLib"),
        // IntellectusLib is the zero-dependency telemetry leaf.
        // NeuronKit emits self-report metrics at hybrid recall, dreaming
        // cycle, and Bradley-Terry boundaries (MANAGER_1.0_PLAN §4 P2
        // self-report coverage; DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28).
        // When monitoring is off (the default), every Intellectus.report(...)
        // call is a single atomic load + branch — zero allocation, no clock.
        // IntellectusLib depends on nothing; layering is safe (it is the
        // new dependency floor below SubstrateKernel).
        .package(path: "../../libs/IntellectusLib"),
        // GeniusLocusKit resolves `EstateHandle` and the nine estate
        // verbs (notably `recall`). All substrate writes flow through
        // this surface; NeuronKit calls no write API on LocusKit,
        // VectorKit, CorpusKit, or PersistenceKit (B-1 invariant). LocusKit
        // is also a direct dependency because the substrate's `Drawer`
        // value type and its read-only adjective-state extensions
        // (notably `isCurrentlyBelieved`) are used to shape the
        // reasoning surface's value types and synthesis math. The
        // read-only value-type access is the B-1 exception
        // MISSION_NK_1A_REASONING_SURFACE acknowledges in its
        // Discoveries section; no LocusKit verb call, no SQL, no
        // storage handle is touched from NeuronKit.
        .package(path: "../GeniusLocusKit"),
        .package(path: "../LocusKit"),
        // EngramLib supplies the typed `Engram` (Fingerprint256) and
        // its `distance(_:_:)` Hamming primitive. NEURONKIT_SPEC § 4.1
        // step 4 mandates that MMR diversity reranking "uses EngramLib's
        // `distance` primitive"; `mmrRank` (MMRRank.swift) computes
        // relevance and inter-candidate similarity from that distance.
        // This is a typed-math dependency only — no substrate, SQL, or
        // estate-verb access — so it is consistent with the B-1
        // invariant that bars direct LocusKit/VectorKit/CorpusKit calls.
        .package(path: "../../libs/EngramLib"),
        .package(path: "../../libs/SubstrateTypes"),
        // SubstrateML supplies the gated reasoning-lens math primitives
        // (EigenvalueCentrality, CommunityDetection, RandomWalks, and the
        // topic/preference/prediction primitives). The reasoning lenses
        // (Sources/NeuronKit/Lenses/) are pure shapes over these primitives
        // and own no math (SPEC I-17); this is a typed-math dependency only,
        // consistent with B-1.
        .package(path: "../../libs/SubstrateML"),
        // PersistenceKit is a test-only dependency: EstateDreamingReaderTests
        // constructs an in-memory estate to integration-test the
        // EstateDreamingReader adapter. No NeuronKit production source
        // touches PersistenceKit; the B-1 invariant is preserved.
        .package(path: "../PersistenceKit"),
    ],
    targets: [
        .target(
            name: "NeuronKit",
            dependencies: [
                .product(name: "EideticLib", package: "EideticLib"),
                // Tokenizer + HMM wordClass tagger for the production feature extractor
                // (HMMFeatureExtractor.swift). Direct dep required: NeuronKit calls
                // LatticeLib symbols directly; transitive access via EideticLib is not
                // stable. Citation: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
                .product(name: "LatticeLib", package: "LatticeLib"),
                // Telemetry leaf — see dependency note above.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                // MMR distance primitive — see dependency note above.
                .product(name: "EngramLib", package: "EngramLib"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                // Gated lens math — see dependency note above (SPEC I-17).
                .product(name: "SubstrateML", package: "SubstrateML"),
            ]
        ),
        .testTarget(
            name: "NeuronKitTests",
            dependencies: [
                "NeuronKit",
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                // SubstrateML provides ARM types (mineAssociationRules,
                // MiningThresholds) used by LensVectorConformanceTests.
                .product(name: "SubstrateML", package: "SubstrateML"),
                // EstateDreamingReaderTests constructs a live GeniusLocusKit
                // estate with an in-memory backend to verify the production
                // adapter delegates all three reads correctly.
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            // Shared conformance vectors — one artifact read by this
            // suite AND rust/tests/lens_conformance.rs (QueueKit's
            // Fixtures pattern).
            resources: [.copy("Fixtures")]
        ),
    ]
)
