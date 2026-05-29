// swift-tools-version:6.0
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
// Platforms: macOS 15 / iOS 18 (Apple Silicon). The Rust port lives
// at `rust/` and is conformance-gated against shared test vectors
// per the SubstrateLib pattern.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category
// "GeniusLocusKit". Per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "GeniusLocusKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "GeniusLocusKit",
            targets: ["GeniusLocusKit"]
        ),
    ],
    dependencies: [
        .package(name: "AriaLexiconLib", path: "../../libs/AriaLexiconLib"),
        .package(name: "SubstrateLib", path: "../../libs/SubstrateLib"),
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
    ],
    targets: [
        .target(
            name: "GeniusLocusKit",
            dependencies: [
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "SubstrateLib", package: "SubstrateLib"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "VectorKit", package: "VectorKit"),
                .product(name: "CorpusKit", package: "CorpusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/GeniusLocusKit"
        ),
        .testTarget(
            name: "GeniusLocusKitTests",
            dependencies: [
                "GeniusLocusKit",
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Tests/GeniusLocusKitTests"
        ),
    ]
)
