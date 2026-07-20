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
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../libs/AriaLexiconLib"),
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
            ],
            path: "Sources/GeniusLocusKit"
        ),
        .testTarget(
            name: "GeniusLocusKitTests",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
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
    ]
)
