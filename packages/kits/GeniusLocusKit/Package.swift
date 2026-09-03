// swift-tools-version:6.2
//
// GeniusLocusKit — the composition layer.
//
// GeniusLocusKit assembles three standalone substrate kits — LocusKit
// (spatial / KG), VectorKit (vectors), CorpusKit (RAG bundles) — into a
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
        .macOS(.v26),
        .iOS(.v26),
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
        // Benchmark-only applicator for a mechanically distilled overlay.
        // It is deliberately a standalone tool: product capture/distillation
        // behavior is unchanged, and callers must point it at a marked clone.
        .executable(
            name: "glk-distilled-overlay",
            targets: ["GLKDistilledOverlay"]
        ),
    ],
    traits: [
        // Step traits name concrete historical code. Floor traits are the
        // consumer-facing cumulative selection and enable every required step.
        .trait(
            name: "MigrationV1_0ToV1_1",
            description: "Compile the historical GLK 1.0 to 1.1 shared-content migration capsule."
        ),
        .trait(
            name: "MigrationV1_1ToV1_2",
            description: "Compile the GLK 1.1 to 1.2 index-composition-column migration capsule."
        ),
        .trait(
            name: "MigrationV1_2ToV1_3",
            description: "Compile the GLK 1.2 to 1.3 distilled-source-digest-column migration capsule."
        ),
        .trait(
            name: "MigrationV1_3ToV1_4",
            description: "Compile the GLK 1.3 to 1.4 index-composition-setting migration capsule."
        ),
        .trait(
            name: "MigrationFloor1_0",
            description: "Support estates as old as GLK format 1.0.",
            enabledTraits: ["MigrationV1_0ToV1_1", "MigrationV1_1ToV1_2", "MigrationV1_2ToV1_3", "MigrationV1_3ToV1_4"]
        ),
        .trait(
            name: "MigrationFloor1_1",
            description: "Support estates as old as GLK format 1.1 (skips the 1.0->1.1 shared-content capsule).",
            enabledTraits: ["MigrationV1_1ToV1_2", "MigrationV1_2ToV1_3", "MigrationV1_3ToV1_4"]
        ),
        .trait(
            name: "MigrationFloor1_2",
            description: "Support estates as old as GLK format 1.2 (compiles the 1.2->1.3 and 1.3->1.4 capsules).",
            enabledTraits: ["MigrationV1_2ToV1_3", "MigrationV1_3ToV1_4"]
        ),
        .trait(
            name: "MigrationFloor1_3",
            description: "Support estates as old as GLK format 1.3 (compiles only the 1.3->1.4 index-composition-setting capsule).",
            enabledTraits: ["MigrationV1_3ToV1_4"]
        ),
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../libs/AriaLexiconLib"),
        // AdornmentLib: dream-time adornment generation and certification.
        // The AdornmentPass (GLK Brain standing signal 13) uses AdornmentLib's
        // MOOT_MINT_CMD seam and AdornmentValidators to mint and certify
        // adornment strings for drawer rows. Layering: AdornmentLib is BELOW
        // GeniusLocusKit (zero kit deps); no inversion. Per BRR Group 10.
        .package(name: "AdornmentLib", path: "../../libs/AdornmentLib"),
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(name: "LocusKit", path: "../LocusKit"),
        .package(name: "VectorKit", path: "../VectorKit"),
        .package(name: "CorpusKit", path: "../CorpusKit"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // EideticLib: the deterministic FDC text-to-anchor utility. GeniusLocusKit's
        // capture_with_mode seam classifies the lattice anchor via EideticLib.lookup
        // when the incoming frame carries the unclassified sentinel "000" and has
        // non-empty content — the one-door principle (all capture paths classify once,
        // here). Per in-repository dependency direction; layering is
        // EideticLib → LatticeLib (below GLK), no inversion.
        .package(name: "EideticLib", path: "../../libs/EideticLib"),
        // LatticeLib: QID/FDC taxonomy and word-class symbols are imported
        // directly by the search/adornment implementation. A transitive path
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
            name: "GLKDistilledOverlay",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Sources/GLKDistilledOverlay"
        ),
        .executableTarget(
            name: "GLKScaleQual",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
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
            ]
        ),
        .target(
            name: "GLKMigrationV1_0ToV1_1",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "VectorKit", package: "VectorKit"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
            ],
            path: "Sources/GLKMigrationV1_0ToV1_1"
        ),
        // GLK 1.1 -> 1.2 capsule: applies corpus_index_state composition_policy
        // column to populated estates that were written before corpus_index_state reached schema version 3.
        // Mirrors the GLKMigrationV1_0ToV1_1 target structure.
        .target(
            name: "GLKMigrationV1_1ToV1_2",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_1ToV1_2",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_1_TO_V1_2",
                    .when(traits: ["MigrationV1_1ToV1_2"])
                ),
            ]
        ),
        // GLK 1.2 -> 1.3 capsule: applies the drawers distilled_source_digest
        // column (LocusKit schema v18) to populated estates that were written
        // before the column existed. Mirrors the GLKMigrationV1_1ToV1_2 target.
        .target(
            name: "GLKMigrationV1_2ToV1_3",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_2ToV1_3",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_2_TO_V1_3",
                    .when(traits: ["MigrationV1_2ToV1_3"])
                ),
            ]
        ),
        // GLK 1.3 -> 1.4 capsule: stores the index composition setting
        // (manifest key index_composition_policy) on populated estates that
        // were written before the setting existed. Mirrors the
        // GLKMigrationV1_2ToV1_3 target; CorpusKit supplies the policy type.
        .target(
            name: "GLKMigrationV1_3ToV1_4",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/GLKMigrationV1_3ToV1_4",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_3_TO_V1_4",
                    .when(traits: ["MigrationV1_3ToV1_4"])
                ),
            ]
        ),
        .target(
            name: "GeniusLocusKitMigrations",
            dependencies: [
                "GeniusLocusKit",
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
                    name: "GLKMigrationV1_1ToV1_2",
                    condition: .when(traits: ["MigrationV1_1ToV1_2"])
                ),
                .target(
                    name: "GLKMigrationV1_2ToV1_3",
                    condition: .when(traits: ["MigrationV1_2ToV1_3"])
                ),
                .target(
                    name: "GLKMigrationV1_3ToV1_4",
                    condition: .when(traits: ["MigrationV1_3ToV1_4"])
                ),
            ],
            path: "Sources/GeniusLocusKitMigrations",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .define(
                    "GLK_MIGRATION_V1_1_TO_V1_2",
                    .when(traits: ["MigrationV1_1ToV1_2"])
                ),
                .define(
                    "GLK_MIGRATION_V1_2_TO_V1_3",
                    .when(traits: ["MigrationV1_2ToV1_3"])
                ),
                .define(
                    "GLK_MIGRATION_V1_3_TO_V1_4",
                    .when(traits: ["MigrationV1_3ToV1_4"])
                ),
            ]
        ),
        .target(
            name: "GeniusLocusKit",
            dependencies: [
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "VectorKit", package: "VectorKit"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                // CorpusKitProviders: the concrete embedding providers. GLK's
                // provision path defaults the Corpus to CorpusEnsemble.defaultEnsemble()
                // (the 1.0 five-signal default), which NEWs concrete providers — so
                // the composition layer needs the providers product. Dependency per
                // in-repository dependency direction; layering is
                // upstream→downstream (CorpusKitProviders ← GeniusLocusKit), no inversion.
                .product(name: "CorpusKitProviders", package: "CorpusKit"),
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
                // AdornmentLib: used by AdornmentPass (Brain standing signal 13)
                // to invoke the MOOT_MINT_CMD seam and certify generated adornments
                // via AdornmentValidators before writing to the drawer row.
                // (BRR Group 10 — GLK Package.swift MUST_UPDATE)
                .product(name: "AdornmentLib", package: "AdornmentLib"),
            ],
            path: "Sources/GeniusLocusKit"
        ),
        .testTarget(
            name: "GeniusLocusKitTests",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                // SubstrateKernel: DatasetSignatureTests calls SHA256.hash
                // directly to verify cross-leg preimage hashes without starting
                // a full estate. (MX-TAB-5, DatasetSignatureTests.swift)
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "VectorKit", package: "VectorKit"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitReplication", package: "PersistenceKit"),
                // PersistenceKitSQLite is required by HydrateRoundTripTests.swift — the
                // round-trip test flushes to an on-disk SQLite backend and hydrates back
                // into a fresh InMemory instance to verify logical equivalence.
                // Blast-radius citation: GLK_HYDRATE_01_BLAST_RADIUS.md §New files item 3.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
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
            path: "Tests/GeniusLocusKitTests"
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
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "VectorKit", package: "VectorKit"),
            ],
            path: "Tests/GLKMigrationV1_0ToV1_1Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
            ]
        ),
        // Tests for the GLK 1.1 -> 1.2 index-composition-column migration capsule.
        // Verifies that corpus_index_state gains composition_policy on v1_1-stamped
        // estates, and that the catalog chain (v1_0 -> v1_1 -> v1_2) ends at v1_2.
        .testTarget(
            name: "GLKMigrationV1_1ToV1_2Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_1ToV1_2",
                    condition: .when(traits: ["MigrationV1_1ToV1_2"])
                ),
                .target(
                    name: "GLKMigrationV1_0ToV1_1",
                    condition: .when(traits: ["MigrationV1_0ToV1_1"])
                ),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_1ToV1_2Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_1_TO_V1_2",
                    .when(traits: ["MigrationV1_1ToV1_2"])
                ),
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
            ]
        ),
        // Tests for the GLK 1.2 -> 1.3 distilled-source-digest-column capsule.
        // Verifies that drawers gains distilled_source_digest on v1_2-stamped
        // estates, and that the catalog chain (v1_0 -> v1_1 -> v1_2 -> v1_3)
        // ends at v1_3.
        .testTarget(
            name: "GLKMigrationV1_2ToV1_3Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_2ToV1_3",
                    condition: .when(traits: ["MigrationV1_2ToV1_3"])
                ),
                .product(name: "ContextDistillLib", package: "ContextDistillLib"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_2ToV1_3Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_2_TO_V1_3",
                    .when(traits: ["MigrationV1_2ToV1_3"])
                ),
                .define(
                    "GLK_MIGRATION_V1_1_TO_V1_2",
                    .when(traits: ["MigrationV1_1ToV1_2"])
                ),
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
            ]
        ),
        // Tests for the GLK 1.3 -> 1.4 index-composition-setting capsule.
        // Verifies that a v1_3-stamped estate without the setting gains it
        // (the creation-time seed) and stamps v1_4, that a second run is a
        // no-op, and that the catalog chain from v1_0 ends at v1_4.
        .testTarget(
            name: "GLKMigrationV1_3ToV1_4Tests",
            dependencies: [
                "GeniusLocusKit",
                "GeniusLocusKitMigrations",
                .target(
                    name: "GLKMigrationV1_3ToV1_4",
                    condition: .when(traits: ["MigrationV1_3ToV1_4"])
                ),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/GLKMigrationV1_3ToV1_4Tests",
            swiftSettings: [
                .define(
                    "GLK_MIGRATION_V1_3_TO_V1_4",
                    .when(traits: ["MigrationV1_3ToV1_4"])
                ),
                .define(
                    "GLK_MIGRATION_V1_0_TO_V1_1",
                    .when(traits: ["MigrationV1_0ToV1_1"])
                ),
            ]
        ),
    ]
)
