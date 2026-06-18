// swift-tools-version:6.2
//
// Package.swift — PersistenceKit
//
// PersistenceKit is the storage abstraction layer for the GeniusLocus
// substrate. It provides typed row, blob, and audit log I/O over
// swappable backends (SQLite, PostgreSQL, InMemory for tests).
//
// PersistenceKit owns no vector-search engine. Dense-embedding k-NN
// lives solely in VectorKit (ADR-008 persistencekit-vector-contract-
// correction). Every backend instead guarantees the ACCOMMODATION
// contract: it accommodates vector workloads' storage needs (vector-
// payload round-trip, bulk hydration, count, delete) through the
// general RowStore / BlobStore surfaces.
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
        // Vendored SQLCipher (Community Edition amalgamation, CommonCrypto
        // backend). Exported so downstream kits that previously used the system
        // SQLite3 module link the SAME encrypted engine — avoiding two sqlite
        // libraries (duplicate sqlite3_* symbols) in one binary.
        .library(name: "SQLCipher", targets: ["SQLCipher"]),
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
        // Vendored SQLCipher amalgamation (Community Edition, CommonCrypto). The
        // SQLite backend links this instead of the system SQLite3 module so
        // estates can be whole-file encrypted (SQLITE_HAS_CODEC + sqlite3_key).
        // SQLCIPHER_CRYPTO_CC selects Apple CommonCrypto (→ CoreCrypto), so there
        // is no OpenSSL on Apple. Plain BSD-licensed source (see LICENSE.md);
        // attribution is reproduced in the app's about/licensing surface.
        .target(
            name: "SQLCipher",
            path: "Sources/SQLCipher",
            exclude: ["LICENSE.md"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                // Mandatory for SQLCipher: wires the codec init/shutdown hooks.
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                // Production SQLite build: asserts off. A SwiftPM debug build does
                // not define NDEBUG, which would leave C asserts active while
                // SQLITE_DEBUG is off — a mismatch that references debug-only
                // internals (sqlite3BtreeHoldsAllMutexes, EdupBuf.zEnd, …). Every
                // shipped SQLite builds with NDEBUG; the codec correctness does
                // not depend on SQLite's internal asserts.
                .define("NDEBUG"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "PersistenceKitSQLite",
            dependencies: ["PersistenceKit", "SubstrateTypes", "SQLCipher"],
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
                // SQLCipher: CorruptReadBackTests opens the raw DB file via the
                // C API, so it links the same vendored engine (not system SQLite3).
                "SQLCipher",
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
                // SQLCipher: IncrementalReplicationTests opens the raw DB via the
                // C API, so it links the same vendored engine (not system SQLite3).
                "SQLCipher",
            ],
            path: "Tests/PersistenceKitReplicationTests"
        ),
    ]
)
