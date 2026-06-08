// swift-tools-version:6.2
//
// Package.swift — PersistenceKit
//
// PersistenceKit is the storage abstraction layer for the GeniusLocus
// substrate. It provides typed row, blob, vector, and audit log
// I/O over swappable backends (SQLite + sqlite-vec, PostgreSQL +
// pgvector, InMemory for tests).
//
// Design per DECISION_STORAGEKIT_DESIGN_2026-05-19.md.
// Eleven-kit graph per DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md.
//
// cp-persistencekit-report (2026-06-06): added IntellectusLib as a
// package dependency so the PersistenceKit core target can emit
// storage-health metrics via Intellectus.report(_:). IntellectusLib is
// the zero-dep telemetry floor; adding it here is strictly
// downstream→upstream (PersistenceKit → IntellectusLib), no cycle.
// Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 +
//            MANAGER_1.0_PLAN §4 (P2 self-report coverage for PersistenceKit).

import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"]),
        .library(name: "PersistenceKitInMemory", targets: ["PersistenceKitInMemory"]),
        .library(name: "PersistenceKitSQLite", targets: ["PersistenceKitSQLite"]),
        .library(name: "PersistenceKitPostgreSQL", targets: ["PersistenceKitPostgreSQL"]),
        // Replication primitive (§5 full-snapshot flush/hydrate).
        // Depends only on the core PersistenceKit protocol surface — no backend
        // target gains a dependency on this library. Recorded in the Blast Radius
        // Report for this mission (pk-replication, NET-NEW module addition).
        .library(name: "PersistenceKitReplication", targets: ["PersistenceKitReplication"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateTypes"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // IntellectusLib: zero-dep telemetry floor. PersistenceKit emits DB-layer
        // health metrics (size, WAL, cache, tx stats) via Intellectus.report(_:),
        // which is a no-op when monitoring is disabled (the default). Off-path
        // cost: one Atomic<Bool> load + branch (~1 ns, lock-free). No lock on
        // the off-path. Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
    ],
    targets: [
        // Vendored sqlite-vec C amalgamation (asg017/sqlite-vec).
        .target(
            name: "CSQLiteVec",
            path: "Sources/CSQLiteVec",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE", to: "1"),
                .define("SQLITE_VEC_STATIC", to: "1"),
            ]
        ),

        // Core protocols and types.
        .target(
            name: "PersistenceKit",
            dependencies: [
                "SubstrateTypes",
                // IntellectusLib: PersistenceKitTelemetry.swift emits storage-health
                // metrics via Intellectus.report(_:). Zero cost when monitoring is
                // disabled (the default). Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.
                "IntellectusLib",
            ],
            path: "Sources/PersistenceKit"
        ),

        // Backends.
        .target(
            name: "PersistenceKitInMemory",
            dependencies: ["PersistenceKit", "SubstrateTypes"],
            path: "Sources/PersistenceKitInMemory"
        ),
        .target(
            name: "PersistenceKitSQLite",
            dependencies: ["PersistenceKit", "SubstrateTypes", "CSQLiteVec"],
            path: "Sources/PersistenceKitSQLite"
        ),
        .target(
            name: "PersistenceKitPostgreSQL",
            dependencies: [
                "PersistenceKit",
                "SubstrateTypes",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Sources/PersistenceKitPostgreSQL"
        ),

        // Replication primitive (§5).
        // NET-NEW module — no existing target gains a dependency on it.
        // Rationale: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 permits controlled
        // intra-repo dependency additions when a recorded architectural decision requires it.
        .target(
            name: "PersistenceKitReplication",
            dependencies: ["PersistenceKit", "SubstrateTypes"],
            path: "Sources/PersistenceKitReplication"
        ),

        // Tests.
        .testTarget(
            name: "PersistenceKitTests",
            dependencies: ["PersistenceKit", "SubstrateTypes"],
            path: "Tests/PersistenceKitTests"
        ),
        .target(
            name: "PersistenceKitConformance",
            dependencies: ["PersistenceKit", "SubstrateTypes"],
            path: "Tests/PersistenceKitConformance"
        ),
        .testTarget(
            name: "PersistenceKitConformanceTests",
            dependencies: ["PersistenceKit", "PersistenceKitConformance", "SubstrateTypes"],
            path: "Tests/PersistenceKitConformanceTests"
        ),
        .testTarget(
            name: "PersistenceKitInMemoryTests",
            dependencies: [
                "PersistenceKit",
                "PersistenceKitInMemory",
                "PersistenceKitConformance",
                "SubstrateTypes",
                // IntellectusLib for telemetry isolation tests (GlobalTestLock + CapturingSink).
                "IntellectusLib",
            ],
            path: "Tests/PersistenceKitInMemoryTests"
        ),
        .testTarget(
            name: "PersistenceKitSQLiteTests",
            dependencies: [
                "PersistenceKit",
                "PersistenceKitSQLite",
                "PersistenceKitConformance",
                "SubstrateTypes",
                // IntellectusLib for telemetry isolation tests (GlobalTestLock + CapturingSink).
                "IntellectusLib",
            ],
            path: "Tests/PersistenceKitSQLiteTests"
        ),
        .testTarget(
            name: "PersistenceKitPostgreSQLTests",
            dependencies: ["PersistenceKit", "PersistenceKitPostgreSQL", "PersistenceKitConformance", "SubstrateTypes"],
            path: "Tests/PersistenceKitPostgreSQLTests"
        ),
        // §9 conformance suite for the replication primitive.
        // Runs against InMemory↔InMemory and InMemory↔SQLite backend pairs.
        .testTarget(
            name: "PersistenceKitReplicationTests",
            dependencies: [
                "PersistenceKit",
                "PersistenceKitReplication",
                "PersistenceKitInMemory",
                "PersistenceKitSQLite",
                "SubstrateTypes",
            ],
            path: "Tests/PersistenceKitReplicationTests"
        ),
    ]
)
