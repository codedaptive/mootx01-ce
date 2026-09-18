// swift-tools-version:6.2
//
// GeniusLocusKit — the composition layer.
//
// GeniusLocusKit assembles three standalone substrate kits — LocusKit
// (spatial / KG), SynapseKit (vectors), CorpusKit (RAG bundles) — into a
// single device-local actor surface that can coordinate N estates.
//
// This package ships the scaffold for that composition: the public
// actor, the EstateHandle value type, the EstateCoordinator (open /
// close / list / per-handle access), and the lattice-scoped read
// fan-out across open estates. The unified nine-verb surface, the
// unified audit log, the Brain layer, and the matrix tier are
// out of scope here and ship in later GLK-* sub-missions.
//
// Composition discipline: GeniusLocusKit depends on the three kits
// through their public products only. It does not import any kit's
// internals, does not modify any of them, and does not assume a
// shared storage backend across estates. Each estate is opened from
// its own manifest with its own injected Storage, mirroring LocusKit's
// dependency-injection convention.
//
// Platforms: macOS 15 / iOS 18 (Apple Silicon). The Rust version lives
// at `rust/` and is conformance-gated against shared test vectors
// per the SubstrateLib pattern.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category
// "GeniusLocusKit". Per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "GeniusLocusKit",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(
            name: "GeniusLocusKit",
            targets: ["GeniusLocusKit"]
        ),
        .library(
            name: "GeniusLocusKitMigrations",
            targets: ["GeniusLocusKitMigrations"]
        ),
        // Maintainer tool: the shared-content scale-qualification driver.
        // A standalone executable (NOT a test) so large-estate qualification
        // runs free of the swiftpm test harness; env-gated exactly like the
        // Rust twin (MOOT_SCF_QUAL_DB names a recoverable clone).
        .executable(
            name: "glk-scale-qual",
            targets: ["GLKScaleQual"]
        ),
    ],
    traits: [
        // Default trait set: every migration capsule, layout and format step.
        //
        // A capsule off by default is a capsule whose tests do not run: a
        // capsule test target compiled without its trait reports zero tests,
        // so the package's own quoted pass count carries no assertion for it.
        // With every step trait default-on, a bare `swift test` in this
        // package runs each GLKMigration*Tests target with a non-zero count.
        //
        // The step targets depend on CorpusKit, SynapseKit and
        // PersistenceKitSQLite, all of which the GeniusLocusKit target already
        // links, so the default build pulls in no package it did not have.
        //
        // No consumer's resolution changes: a consumer that names traits on
        // this package replaces the default set, and every product manifest
        // selects a MigrationFloor, which enables the steps it needs.
        .default(enabledTraits: [
            "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog",
            "MigrationV1_0ToV1_1", "MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6",
            "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10",
        ]),
        // Step traits name concrete historical code. Floor traits are the
        // consumer-facing cumulative selection and enable every required step.
        .trait(
            name: "MigrationV1_0ToV1_1",
            description: "Compile the historical GLK 1.0 to 1.1 shared-content migration capsule."
        ),
        .trait(
            name: "MigrationV1_4ToV1_5",
            description: "Compile the GLK 1.4 to 1.5 storage-ledger kit-id migration capsule (SynapseKit ledger rows become SynapseKit rows)."
        ),
        .trait(
            name: "MigrationV1_5ToV1_6",
            description: "Compile the GLK 1.5 to 1.6 migration capsule (drops the retired corpus_index_state.composition_policy column)."
        ),
        .trait(
            name: "MigrationV1_6ToV1_7",
            description: "Compile the GLK 1.6 to 1.7 migration capsule (vacuums the whole-record float rows and the hnsw_graph rows, rebuilds the binary sidecar, releases the float representation claim)."
        ),
        .trait(
            name: "MigrationV1_7ToV1_8",
            description: "Compile the GLK 1.7 to 1.8 migration capsule (seeds fact_extraction = on when absent and stamps the v1_8 estate format)."
        ),
        .trait(
            name: "MigrationV1_8ToV1_9",
            description: "Compile the GLK 1.8 to 1.9 migration capsule (seeds the five remaining preferences on when absent, creates recall_ratings and stamps the v1_9 estate format)."
        ),
        .trait(name: "MigrationV1_9ToV1_10", description: "Offline matrix BLOB retirement and record rebuild."),
        .trait(name: "MigrationFloor1_8", description: "Support estate format 1.8.", enabledTraits: ["MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10"]),
        .trait(name: "MigrationFloor1_9", description: "Support estate format 1.9.", enabledTraits: ["MigrationV1_9ToV1_10"]),
        // Layout capsule, not a format step: a 1.0.x Swift install kept its
        // estate flat in the configuration directory; the catalog places it
        // at databases/default/. Detected by the filesystem, not by the
        // format stamp, so no format version separates the two layouts.
        // Every floor from 1.0 through 1.6 enables it; MigrationFloor1_7
        // omits it because a format 1.7 estate was already produced by a
        // build that writes the catalog layout.
        .trait(
            name: "MigrationFlatLayoutToCatalog",
            description: "Compile the flat-layout to catalog-layout capsule (moves a pre-catalog estate from the configuration directory into databases/default/)."
        ),
        // Layout capsule for the app: a pre-catalog Apple app kept its estate
        // at <Application Support>/mootx01/mootx01.sqlite inside its container;
        // the catalog places it at databases/default/estate.sqlite. Same
        // floors as the flat capsule, same retirement.
        .trait(
            name: "MigrationAppContainerToCatalog",
            description: "Compile the app-container to catalog-layout capsule (moves a pre-catalog app estate from <Application Support>/mootx01/mootx01.sqlite into databases/default/estate.sqlite)."
        ),
        // Floors 1.1 through 1.4 compile the same three capsules: the 1.1->1.2
        // column is added by CorpusKit's own ladder at open, the 1.2->1.3 column
        // was removed by schema v19, and the 1.3->1.4 setting retired with the
        // index composition policy, so the 1.4->1.5 capsule runs directly on
        // any of those stamps; the 1.5->1.6, 1.6->1.7, 1.7->1.8 and 1.8->1.9
        // capsules follow it.
        .trait(
            name: "MigrationFloor1_0",
            description: "Support estates as old as GLK format 1.0.",
            enabledTraits: ["MigrationV1_0ToV1_1", "MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_1",
            description: "Support estates as old as GLK format 1.1 (skips the 1.0->1.1 shared-content capsule; compiles the 1.4->1.5, 1.5->1.6, 1.6->1.7, 1.7->1.8 and 1.8->1.9 capsules).",
            enabledTraits: ["MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_2",
            description: "Support estates as old as GLK format 1.2 (compiles the 1.4->1.5, 1.5->1.6, 1.6->1.7, 1.7->1.8 and 1.8->1.9 capsules).",
            enabledTraits: ["MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_3",
            description: "Support estates as old as GLK format 1.3 (compiles the 1.4->1.5, 1.5->1.6, 1.6->1.7, 1.7->1.8 and 1.8->1.9 capsules).",
            enabledTraits: ["MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_4",
            description: "Support estates as old as GLK format 1.4 (compiles the 1.4->1.5 storage-ledger kit-id capsule, the 1.5->1.6 capsule, the 1.6->1.7 capsule, the 1.7->1.8 capsule and the 1.8->1.9 capsule).",
            enabledTraits: ["MigrationV1_4ToV1_5", "MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_5",
            description: "Support estates as old as GLK format 1.5 (compiles the 1.5->1.6 column-drop capsule, the 1.6->1.7 vacuum capsule, the 1.7->1.8 seed capsule and the 1.8->1.9 preference-seed capsule).",
            enabledTraits: ["MigrationV1_5ToV1_6", "MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_6",
            description: "Support estates as old as GLK format 1.6 (compiles the 1.6->1.7 whole-record float vacuum capsule, the 1.7->1.8 fact-extraction seed capsule and the 1.8->1.9 preference-seed capsule).",
            enabledTraits: ["MigrationV1_6ToV1_7", "MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10", "MigrationFlatLayoutToCatalog", "MigrationAppContainerToCatalog"]
        ),
        .trait(
            name: "MigrationFloor1_7",
            description: "Support estates as old as GLK format 1.7 (compiles the 1.7->1.8 fact-extraction-setting seed capsule and the 1.8->1.9 preference-seed capsule).",
            enabledTraits: ["MigrationV1_7ToV1_8", "MigrationV1_8ToV1_9", "MigrationV1_9ToV1_10"]
        ),
        // Apple encoder providers (NLContextualEmbedding, NLEmbedding, NeuralEmbed).
        // Off by default: retained in case Apple improves the NaturalLanguage framework,
        // or for a device class that cannot host a Core AI encoder. Mirror of
        // CorpusKit's AppleEncoders trait and APPLE_ENCODERS Swift define.
        // Enable: --traits AppleEncoders.
        .trait(
            name: "AppleEncoders",
            description: "Compile apple-nl-v1 and neural-embed-v1 provisioning paths in EstateLifecycle. Off by default; retained for device classes that cannot host Core AI encoders or when the NaturalLanguage framework improves. Enable: --traits AppleEncoders."
        ),
        // CrossEncoder: lets the retrieval-time cross-encoder stage load the
        // packaged pair classifier (PairScorerFactory over Core AI). The
        // request field, the report and the fusion rule compile regardless;
        // with the trait off an `apply` directive degrades with reason
        // `capability_off`. Twin of the Rust feature `cross-encoder`
        // (`corpus-kit-providers/candle`). The product targets enable it.
        .trait(
            name: "CrossEncoder",
            description: "Compile the cross-encoder scorer load (PairScorerFactory over Core AI) behind the retrieval-time rerank stage. Off by default in the kit; enabled by the product targets. Defines MOOTX01_CROSS_ENCODER."
        ),
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../libs/AriaLexiconLib"),
        // GeniusLocusKit (zero kit deps); no inversion. Per BRR Group 10.
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../../libs/MootProductIdentity"),
        // EstateEncryption: the estate file classification (plaintext or
        // ciphertext by header) and the harness key file that
        // `EstateOpenPosture` decides the at-rest posture from. A library below
        // the kit (it depends on PersistenceKit only); no inversion.
        .package(name: "EstateEncryption", path: "../../libs/EstateEncryption"),
        .package(name: "LocusKit", path: "../LocusKit"),
        .package(name: "SynapseKit", path: "../SynapseKit"),
        // CorpusKit traits follow this package's: AppleEncoders compiles the
        // Apple NL providers in CorpusKitProviders.
        .package(name: "CorpusKit", path: "../CorpusKit", traits: [
            // AppleEncoders compiles AppleNLProvider and NeuralEmbedProvider in
            // CorpusKitProviders, which EstateLifecycle wires under APPLE_ENCODERS.
            .trait(name: "AppleEncoders", condition: .when(traits: ["AppleEncoders"])),
        ]),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // EideticLib: the deterministic FDC text-to-anchor utility. GeniusLocusKit's
        // capture_with_mode seam classifies the lattice anchor via EideticLib.lookup
        // when the incoming frame carries the unclassified sentinel "000" and has
        // non-empty content — the one-door principle (all capture paths classify once,
        // here). Per in-repository dependency direction; layering is
        // EideticLib → LatticeLib (below GLK), no inversion.
        .package(name: "EideticLib", path: "../../libs/EideticLib"),
        // LatticeLib: QID/FDC taxonomy and word-class symbols are imported
        // through EideticLib is insufficient when GeniusLocusKit is linked as
        // a dynamic product by an Xcode application target.
        .package(name: "LatticeLib", path: "../../libs/LatticeLib"),
        // QueueKit is the twelfth kit in the graph.
        // GLK-04 consumes it as the single-serial-dispatch substrate for
        // standing signals: scheduler enqueues jobs through QueueKit; a
        // single drainer applies them through the propose verb.
        .package(name: "QueueKit", path: "../QueueKit"),
        // SubstrateML (Layer 3 algorithms) is required by GeniusLocusKit so
        // MatrixTier.rebuildTemporal can call TemporalCausalityFold — the
        // canonical T-matrix population engine (cookbook §6.4).
        // Dependency added 2026-06-04.
        // Layering: GeniusLocusKit (composition) → SubstrateML (algorithms) does
        // NOT invert — SubstrateML is below GeniusLocusKit in the kit graph.
        .package(path: "../../libs/SubstrateML"),
        // ContextDistillLib: the deterministic dense-context distiller (CDL-02).
        // GeniusLocusKit's distillation stage produces the stored `distilled`
        // representation by calling ContextDistiller; the library's converter ID
        // is the value written to `distilled_pipeline_version`. Layering:
        // ContextDistillLib is foundation tier (zero kit deps); no inversion.
        .package(path: "../../libs/ContextDistillLib"),
        // Provider-neutral contract for distilled, source-grounded KGFact
        // extraction. Concrete Apple and worker runtimes live in provider
        // targets; GLK owns only activation, duty orchestration and filing.
        .package(path: "../FactExtractionKit"),
        // IntellectusLib is the zero-dependency telemetry floor. GeniusLocusKit
        // emits per-estate rollup metrics at open/close/provision/quiesce/drain
        // and at the verb-error boundary (GLK_ROLLUPS_001). When monitoring is
        // disabled (the default), each emit is a single Atomic<Bool> load —
        // zero allocation, no lock, results byte-identical to the pre-telemetry
        // code. Per in-repository dependency direction: layering is
        // GeniusLocusKit (composition) → IntellectusLib (floor). No inversion.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
        // ConvergenceKit: sync-backend abstraction. GeniusLocusKit stores the
        // active sync engine per estate and exposes its state through
        // syncState(for:) so ARIA surfaces can report honest sync status.
        // Layering: GeniusLocusKit (composition) → ConvergenceKit (sync tier)
        // does NOT invert. ConvergenceKit has no dependency on GLK.
        // Per in-repository dependency direction.
        .package(name: "ConvergenceKit", path: "../ConvergenceKit"),
    ],
    targets: [
        .executableTarget(
            name: "GLKScaleQual",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "CorpusKitWholeRecordDense", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Sources/GLKScaleQual",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        .target(
            name: "GLKMigrationV1_0ToV1_1",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
            ],
            path: "Sources/GLKMigrationV1_0ToV1_1"
        ),
        // GLK 1.4 -> 1.5 capsule: moves the vector tier's schema-version
        // ledger rows from their SynapseKit ids to their SynapseKit ids on
        // populated estates, through PersistenceKit's renameSchemaKit.
        // Mirrors the GLKMigrationV1_0ToV1_1 target structure.
        .target(
            name: "GLKMigrationV1_4ToV1_5",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                // The capsule reads the VectorKit→SynapseKit ledger rename pair
                // from SynapseKit's kitID/formerKitIDs constants (one source).
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Sources/GLKMigrationV1_4ToV1_5",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_4_TO_V1_5",
                    .when(traits: ["MigrationV1_4ToV1_5"])
                ),
            ]
        ),
        // GLK 1.5 -> 1.6 capsule: drops the retired
        // corpus_index_state.composition_policy column from populated estates
        // by replaying CorpusKit's checkpoint ladder (v4) on the estate
        // storage. Mirrors the GLKMigrationV1_4ToV1_5 target structure.
        .target(
            name: "GLKMigrationV1_5ToV1_6",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_5ToV1_6",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_5_TO_V1_6",
                    .when(traits: ["MigrationV1_5ToV1_6"])
                ),
            ]
        ),
        // GLK 1.6 -> 1.7 capsule: vacuums the whole-record float rows
        // (vectors kind 1) and the hnsw_graph rows from populated estates,
        // rebuilds the binary sidecar and releases the float representation
        // claim. Mirrors the GLKMigrationV1_5ToV1_6 target structure. Under the
        // The capsule reads the manifest and leaves an audition estate's rows in place.
        .target(
            name: "GLKMigrationV1_6ToV1_7",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Sources/GLKMigrationV1_6ToV1_7",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_6_TO_V1_7",
                    .when(traits: ["MigrationV1_6ToV1_7"])
                ),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        // 1.7 -> 1.8 migration target: seeds fact_extraction = "on" when the
        // key is absent and stamps v1_8. Mirrors GLKMigrationV1_6ToV1_7 target
        // structure. The absent-means-on inversion is documented in
        // EstatePreference.swift; this capsule only writes when absent.
        .target(
            name: "GLKMigrationV1_7ToV1_8",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_7ToV1_8",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_7_TO_V1_8",
                    .when(traits: ["MigrationV1_7ToV1_8"])
                ),
            ]
        ),
        // 1.8 -> 1.9 migration target: seeds the five remaining preferences
        // "on" when absent, creates the recall_ratings table and stamps v1_9.
        // Mirrors the GLKMigrationV1_7ToV1_8 target structure; writes a
        // preference only when its key is absent.
        .target(
            name: "GLKMigrationV1_8ToV1_9",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_8ToV1_9",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_8_TO_V1_9",
                    .when(traits: ["MigrationV1_8ToV1_9"])
                ),
            ]
        ),
        .target(name: "GLKMigrationV1_9ToV1_10", dependencies: [
            "GeniusLocusKit", .product(name: "PersistenceKit", package: "PersistenceKit")
        ]),
        // Flat-layout -> catalog-layout capsule: renames a pre-catalog
        // estate's files from the configuration directory into the default
        // record's directory. Filesystem only; depends on GeniusLocusKit for
        // the catalog names and the record type.
        .target(
            name: "GLKMigrationFlatLayoutToCatalog",
            dependencies: ["GeniusLocusKit", .product(name: "MootProductIdentity", package: "MootProductIdentity")],
            path: "Sources/GLKMigrationFlatLayoutToCatalog"
        ),
        // App-container layout capsule: moves a pre-catalog Apple app estate
        // (<Application Support>/mootx01/mootx01.sqlite and its WAL/SHM) into
        // the default record's directory under the catalog's names, key first.
        .target(
            name: "GLKMigrationAppContainerToCatalog",
            dependencies: ["GeniusLocusKit", .product(name: "MootProductIdentity", package: "MootProductIdentity")],
            path: "Sources/GLKMigrationAppContainerToCatalog"
        ),
        .target(
            name: "GeniusLocusKitMigrations",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                // PersistenceKit: GeometryNormalizationCapsule casts to
                // `any StorageMaintenance` and uses `GeometryNormalizationReport` —
                // both defined in PersistenceKit. The transitive dependency through
                // GeniusLocusKit does not guarantee explicit module visibility in
                // Swift 6 strict concurrency builds, so we declare it directly.
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .target(
                    name: "GLKMigrationV1_0ToV1_1",
                    condition: .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .target(
                    name: "GLKMigrationV1_4ToV1_5",
                    condition: .when(traits: ["MigrationV1_4ToV1_5"])
                ),
                .target(
                    name: "GLKMigrationV1_5ToV1_6",
                    condition: .when(traits: ["MigrationV1_5ToV1_6"])
                ),
                .target(
                    name: "GLKMigrationV1_6ToV1_7",
                    condition: .when(traits: ["MigrationV1_6ToV1_7"])
                ),
                .target(
                    name: "GLKMigrationV1_7ToV1_8",
                    condition: .when(traits: ["MigrationV1_7ToV1_8"])
                ),
                .target(
                    name: "GLKMigrationV1_8ToV1_9",
                    condition: .when(traits: ["MigrationV1_8ToV1_9"])
                ),
                .target(name: "GLKMigrationV1_9ToV1_10", condition: .when(traits: ["MigrationV1_9ToV1_10"])),
                .target(
                    name: "GLKMigrationFlatLayoutToCatalog",
                    condition: .when(traits: ["MigrationFlatLayoutToCatalog"])
                ),
                .target(
                    name: "GLKMigrationAppContainerToCatalog",
                    condition: .when(traits: ["MigrationAppContainerToCatalog"])
                ),
            ],
            path: "Sources/GeniusLocusKitMigrations",
            swiftSettings: [
                .define("GLK_MIGRATION_V1_9_TO_V1_10", .when(traits: ["MigrationV1_9ToV1_10"])),
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .define(
                    "GLK_MIGRATION_V1_4_TO_V1_5",
                    .when(traits: ["MigrationV1_4ToV1_5"])
                ),
                .define(
                    "GLK_MIGRATION_V1_5_TO_V1_6",
                    .when(traits: ["MigrationV1_5ToV1_6"])
                ),
                .define(
                    "GLK_MIGRATION_V1_6_TO_V1_7",
                    .when(traits: ["MigrationV1_6ToV1_7"])
                ),
                .define(
                    "GLK_MIGRATION_V1_7_TO_V1_8",
                    .when(traits: ["MigrationV1_7ToV1_8"])
                ),
                .define(
                    "GLK_MIGRATION_V1_8_TO_V1_9",
                    .when(traits: ["MigrationV1_8ToV1_9"])
                ),
                .define(
                    "GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG",
                    .when(traits: ["MigrationFlatLayoutToCatalog"])
                ),
                .define(
                    "GLK_MIGRATION_APP_CONTAINER_TO_CATALOG",
                    .when(traits: ["MigrationAppContainerToCatalog"])
                ),
            ]
        ),
        .target(
            name: "GeniusLocusKit",
            dependencies: [
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                .product(name: "EstateEncryption", package: "EstateEncryption"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                // CorpusKitProviders: the concrete embedding providers. GLK's
                // provision path defaults the Corpus to CorpusEnsemble.defaultEnsemble()
                // (RI + LSA), which NEWs concrete providers — the composition layer
                // needs the providers product. Dependency per in-repository dependency
                // direction; layering is upstream→downstream (CorpusKitProviders ← GeniusLocusKit),
                // no inversion.
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                // CorpusKitWholeRecordDense: the float query surface the
                // unionBest whole-record lane reads.
                .product(name: "CorpusKitWholeRecordDense", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitReplication (§5 full-snapshot flush/hydrate).
                // Required by EstateHydration.swift — open(inMemory:owner:hydrateFrom:)
                // and rebuildDerivedAccelerators(for:) call StorageReplicator.hydrate to
                // populate an in-memory estate from a durable backend on launch.
                // Dependency per in-repository dependency direction: recorded in
                // GLK_HYDRATE_01_BLAST_RADIUS.md §Symbol 2. Layering is upstream→downstream
                // (PersistenceKit ← GeniusLocusKit); no inversion.
                .product(name: "PersistenceKitReplication", package: "PersistenceKit"),
                // PersistenceKitSQLite: `ensureScheduler` opens the shared encrypted
                // `queue.sqlite` sibling via `SQLiteStorage(configuration:)` for
                // persistent estates. Same encrypted SQLite
                // the encode stream uses — `queueSibling` derives the sibling config
                // so signal jobs share the per-estate queue.sqlite without a separate
                // file. Dependency per in-repository dependency direction;
                // layering is upstream→downstream (PersistenceKit ← GeniusLocusKit).
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "ContextDistillLib", package: "ContextDistillLib"),
                .product(name: "FactExtractionKit", package: "FactExtractionKit"),
                // IntellectusLib: per-estate rollup telemetry (GLK_ROLLUPS_001).
                // Off-path is a single Atomic<Bool> load — zero cost when disabled.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                // ConvergenceKit: sync-backend protocol + SyncState. GLK stores the
                // active SyncEngine per estate handle and exposes syncState(for:)
                // so honest sync status flows from ConvergenceKit → GLK → ARIA.
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                // EideticLib: used by the capture_with_mode seam to classify the
                // lattice anchor at the one capture door (one-door principle).
                .product(name: "EideticLib", package: "EideticLib"),
                // LatticeLib is referenced directly by QID/FDC search paths.
                // Keep it direct so dynamic application linkage exports the
                // symbols instead of relying on EideticLib's transitive edge.
                .product(name: "LatticeLib", package: "LatticeLib"),
                // (BRR Group 10 — GLK Package.swift MUST_UPDATE)
            ],
            path: "Sources/GeniusLocusKit",
            swiftSettings: [
                // AppleEncoders: gates apple-nl-v1 and neural-embed-v1 provisioning
                // paths in EstateLifecycle.swift. Off by default; retained for device
                // classes that cannot host Core AI encoders. Mirror of CorpusKit
                // AppleEncoders trait.
                .define("APPLE_ENCODERS", .when(traits: ["AppleEncoders"])),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        .testTarget(
            name: "GeniusLocusKitTests",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "FactExtractionKit", package: "FactExtractionKit"),
                .product(name: "FactExtractionKitProviders", package: "FactExtractionKit"),
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                // SubstrateKernel: DatasetSignatureTests calls SHA256.hash
                // directly to verify cross-leg preimage hashes without starting
                // a full estate. (MX-TAB-5, DatasetSignatureTests.swift)
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "LocusKit", package: "LocusKit"),
                // LocusKitEstateFixture: the twenty-row plaintext estate the
                // open-posture tests classify and reopen.
                .product(name: "LocusKitEstateFixture", package: "LocusKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitWholeRecordDense", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitReplication", package: "PersistenceKit"),
                // PersistenceKitSQLite is required by HydrateRoundTripTests.swift — the
                // round-trip test flushes to an on-disk SQLite backend and hydrates back
                // into a fresh InMemory instance to verify logical equivalence.
                // Blast-radius citation: GLK_HYDRATE_01_BLAST_RADIUS.md §New files item 3.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // PersistenceKitTestSupport: faulting Storage/RowStore decorator used
                // by FailClosedPreReadTests to drive the thrown-error branch of the
                // fail-closed pre-read paths in `expunge` and `retireKGFact`.
                .product(name: "PersistenceKitTestSupport", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                // IntellectusLib: test suite needs to install capturing sinks
                // and toggle the enabled flag for telemetry isolation tests.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
                // ConvergenceKit: sync-engine test types (NoSyncEngine) used by
                // sync-state force-tests in EstateStatusSyncTests.swift.
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                .product(name: "ConvergenceKitNone", package: "ConvergenceKit"),
            ],
            path: "Tests/GeniusLocusKitTests",
            swiftSettings: [
                // Mirror the production trait defines into the test target.
                .define("APPLE_ENCODERS", .when(traits: ["AppleEncoders"])),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        .testTarget(
            name: "GeniusLocusKitMigrationsTests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // SQLCipher: test fixtures use the raw C API (sqlite3_file_control) to
                // inject reserve=12 geometry before the first page write — the only way
                // to set the reserve without an engine-path round-trip. Legitimate in
                // tests only; production code never spawns raw connections to estate files.
                .product(name: "SQLCipher", package: "PersistenceKit"),
            ],
            path: "Tests/GeniusLocusKitMigrationsTests"
        ),
        .testTarget(
            name: "GLKMigrationV1_0ToV1_1Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_0ToV1_1",
                    condition: .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "CorpusKitWholeRecordDense", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Tests/GLKMigrationV1_0ToV1_1Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        // Tests for the GLK 1.4 -> 1.5 storage-ledger kit-id capsule.
        // Verifies that a v1_4-stamped estate carrying the SynapseKit ledger
        // rows ends with SynapseKit rows at the same versions and a v1_5
        // stamp, that a second run is a no-op, that an estate without the
        // rows is stamped without change, and that the chain from v1_0 ends
        // at v1_5.
        .testTarget(
            name: "GLKMigrationV1_4ToV1_5Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_4ToV1_5",
                    condition: .when(traits: ["MigrationV1_4ToV1_5"])
                ),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Tests/GLKMigrationV1_4ToV1_5Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_4_TO_V1_5",
                    .when(traits: ["MigrationV1_4ToV1_5"])
                ),
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
            ]
        ),
        // Tests for the GLK 1.5 -> 1.6 column-drop capsule. Verifies that a
        // v1_5-stamped estate carrying corpus_index_state.composition_policy
        // (with or without a CorpusKitIndexState ledger row) ends without the
        // column, its checkpoint rows intact, and a v1_6 stamp; that a second
        // run is a no-op; that a fresh estate is stamped without the capsule;
        // and that the chain from v1_4 ends at v1_6.
        .testTarget(
            name: "GLKMigrationV1_5ToV1_6Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_5ToV1_6",
                    condition: .when(traits: ["MigrationV1_5ToV1_6"])
                ),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_5ToV1_6Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_5_TO_V1_6",
                    .when(traits: ["MigrationV1_5ToV1_6"])
                ),
                .define(
                    "GLK_MIGRATION_V1_4_TO_V1_5",
                    .when(traits: ["MigrationV1_4ToV1_5"])
                ),
                .define(
                    "GLK_MIGRATION_V1_6_TO_V1_7",
                    .when(traits: ["MigrationV1_6ToV1_7"])
                ),
            ]
        ),
        // Tests for the GLK 1.6 -> 1.7 whole-record float vacuum capsule. A
        // v1_6-stamped estate carrying binary, float and span rows and an
        // hnsw_graph row ends with the float and graph rows gone, the binary
        // and span rows intact, the sidecar loading without a rebuild, the
        // same ordered binary neighbours, the float representation claim
        // released and a v1_7 stamp; a second run is a no-op; the chain from
        // v1_5 ends at v1_7; an audition estate keeps its rows.
        .testTarget(
            name: "GLKMigrationV1_6ToV1_7Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_6ToV1_7",
                    condition: .when(traits: ["MigrationV1_6ToV1_7"])
                ),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "SynapseKit", package: "SynapseKit"),
            ],
            path: "Tests/GLKMigrationV1_6ToV1_7Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_6_TO_V1_7",
                    .when(traits: ["MigrationV1_6ToV1_7"])
                ),
                .define(
                    "GLK_MIGRATION_V1_5_TO_V1_6",
                    .when(traits: ["MigrationV1_5ToV1_6"])
                ),
                .define("MOOTX01_CROSS_ENCODER", .when(traits: ["CrossEncoder"])),
            ]
        ),
        // Tests for the 1.7 -> 1.8 capsule: absent-means-on seeding, idempotent
        // stamp, explicit-off preserved, v1_8 stamped, chain integration.
        .testTarget(
            name: "GLKMigrationV1_7ToV1_8Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_7ToV1_8",
                    condition: .when(traits: ["MigrationV1_7ToV1_8"])
                ),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_7ToV1_8Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_7_TO_V1_8",
                    .when(traits: ["MigrationV1_7ToV1_8"])
                ),
            ]
        ),
        // Tests for the 1.8 -> 1.9 capsule: the five preferences seeded, the
        // recall_ratings table created, explicit-off preserved, v1_9 stamped,
        // chain integration from v1_8.
        .testTarget(
            name: "GLKMigrationV1_8ToV1_9Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_8ToV1_9",
                    condition: .when(traits: ["MigrationV1_8ToV1_9"])
                ),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_8ToV1_9Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_8_TO_V1_9",
                    .when(traits: ["MigrationV1_8ToV1_9"])
                ),
            ]
        ),
        .testTarget(
            name: "GLKMigrationV1_9ToV1_10Tests",
            dependencies: [
                "GeniusLocusKit",
                .target(name: "GLKMigrationV1_9ToV1_10", condition: .when(traits: ["MigrationV1_9ToV1_10"])),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "LocusKit", package: "LocusKit")
            ],
            swiftSettings: [.define("GLK_MIGRATION_V1_9_TO_V1_10", .when(traits: ["MigrationV1_9ToV1_10"]))]
        ),
        // Tests for the app-container -> catalog-layout capsule over temporary
        // directories: no-op, full move with rename, partial move, refusal,
        // other records left alone, resume, key hook order, emptied legacy
        // folder removed.
        .testTarget(
            name: "GLKMigrationAppContainerToCatalogTests",
            dependencies: [
                "GeniusLocusKit",
                .target(
                    name: "GLKMigrationAppContainerToCatalog",
                    condition: .when(traits: ["MigrationAppContainerToCatalog"])
                ),
            ],
            path: "Tests/GLKMigrationAppContainerToCatalogTests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_APP_CONTAINER_TO_CATALOG",
                    .when(traits: ["MigrationAppContainerToCatalog"])
                ),
            ]
        ),
        // Tests for the flat-layout -> catalog-layout capsule over temporary
        // directories: no-op, full move, partial move, refusal when both
        // layouts hold a database, non-default records left alone, resume
        // after an interrupted move.
        .testTarget(
            name: "GLKMigrationFlatLayoutToCatalogTests",
            dependencies: [
                "GeniusLocusKit",
                .target(
                    name: "GLKMigrationFlatLayoutToCatalog",
                    condition: .when(traits: ["MigrationFlatLayoutToCatalog"])
                ),
            ],
            path: "Tests/GLKMigrationFlatLayoutToCatalogTests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG",
                    .when(traits: ["MigrationFlatLayoutToCatalog"])
                ),
            ]
        ),
    ]
)
