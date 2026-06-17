// swift-tools-version: 6.2
// LocusKit — Loci databases for MOOTx01.
//
// Apple Silicon only (macOS 15 / iOS 18). Storage is provided by
// PersistenceKit: LocusKit declares its schema in PersistenceKit primitives
// and persists through the Storage protocol rather than the raw
// SQLite3 C API. The concrete backend (SQLite or in-memory) is
// injected by the caller; tests use both. Logging uses Apple OSLog
// with the fleet subsystem "com.mootx01.kit".
//
// LocusKit composes — it does not inherit. DrawerStore is the public
// actor surface over the storage primitives: drawer/tunnel/diary/
// kg_fact value types, the LocusKitError enum, the LocusKitSchema
// declaration, and the actor itself.
//
// Embedding generation, vector retrieval, the search pipeline, the
// directory walker, and the MCP server are out of scope here and
// ship in subsequent LOCI-* missions.
//
// cp-locuskit-report: added IntellectusLib self-report telemetry.
// Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + MANAGER_1.0_PLAN §4
// (P2 self-report coverage). Layering: IntellectusLib has zero repo deps;
// adding it here is strictly downstream→upstream, no cycle.

import PackageDescription

let package = Package(
    name: "LocusKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "LocusKit",
            targets: ["LocusKit"]
        ),
    ],
    dependencies: [
        .package(name: "SubstrateLib", path: "../../libs/SubstrateLib"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateML"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // IntellectusLib is the zero-dep telemetry floor. LocusKit emits
        // path, recall, and KG-fact operation metrics via Intellectus.report(_:),
        // which is a no-op when monitoring is disabled (the default).
        // Off-path cost: one Atomic<Bool> load + branch (~1 ns). No lock on the
        // off-path. Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + MANAGER_1.0_PLAN §4.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
        // LatticeLib supplies QIDClosure: the pinned Q-ID taxonomic-closure
        // surface DrawerFingerprint hashes into the lattice-block
        // `qidClosureHash` slot (mission #7b). LatticeLib is a libs/ library
        // that imports no substrate kit — the edge is strictly downstream→
        // upstream (kit → lib), no cycle. Authority:
        // DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 (the #7 feature requires it).
        .package(name: "LatticeLib", path: "../../libs/LatticeLib"),
    ],
    targets: [
        .target(
            name: "LocusKit",
            dependencies: [
                .product(name: "SubstrateLib", package: "SubstrateLib"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                "IntellectusLib",
                .product(name: "LatticeLib", package: "LatticeLib"),
            ],
            path: "Sources/LocusKit"
        ),
        .testTarget(
            name: "LocusKitTests",
            dependencies: [
                "LocusKit",
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                "IntellectusLib",
            ],
            path: "Tests/LocusKitTests"
        ),
    ]
)
