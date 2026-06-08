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
        // QueueKit is the twelfth kit in the graph (DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21).
        // GLK-04 consumes it as the single-serial-dispatch substrate for
        // standing signals: scheduler enqueues jobs through QueueKit; a
        // single drainer applies them through the propose verb.
        .package(name: "QueueKit", path: "../QueueKit"),
        // SubstrateML (Layer 3 algorithms) is required by GeniusLocusKit so
        // MatrixTier.rebuildTemporal can call TemporalCausalityFold — the
        // canonical T-matrix population engine (cookbook §6.4).
        // Dependency added 2026-06-04 per DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md.
        // Layering: GeniusLocusKit (composition) → SubstrateML (algorithms) does
        // NOT invert — SubstrateML is below GeniusLocusKit in the kit graph.
        .package(path: "../../libs/SubstrateML"),
        // IntellectusLib is the zero-dependency telemetry floor. GeniusLocusKit
        // emits per-estate rollup metrics at open/close/provision/quiesce/drain
        // and at the verb-error boundary (GLK_ROLLUPS_001). When monitoring is
        // disabled (the default), each emit is a single Atomic<Bool> load —
        // zero allocation, no lock, results byte-identical to the pre-telemetry
        // code. Per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28: layering is
        // GeniusLocusKit (composition) → IntellectusLib (floor). No inversion.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
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
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitReplication (§5 full-snapshot flush/hydrate).
                // Required by EstateHydration.swift — open(inMemory:owner:hydrateFrom:)
                // and rebuildDerivedAccelerators(for:) call StorageReplicator.hydrate to
                // populate an in-memory estate from a durable backend on launch.
                // Dependency per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28: recorded in
                // GLK_HYDRATE_01_BLAST_RADIUS.md §Symbol 2. Layering is upstream→downstream
                // (PersistenceKit ← GeniusLocusKit); no inversion.
                .product(name: "PersistenceKitReplication", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                // IntellectusLib: per-estate rollup telemetry (GLK_ROLLUPS_001).
                // Off-path is a single Atomic<Bool> load — zero cost when disabled.
                .product(name: "IntellectusLib", package: "IntellectusLib"),
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
            ],
            path: "Tests/GeniusLocusKitTests"
        ),
    ]
)
