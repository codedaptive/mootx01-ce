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
        // swift-nio-ssl: provides NIOSSLContext for PostgreSQL TLS (SECFIX-WS2-PK F3).
        // Already a transitive dep (postgres-nio requires it); made explicit here
        // so SPM 6 strict mode allows the PersistenceKitPostgreSQL target to import NIOSSL.
        // No new external package is added to the resolved graph.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
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
            // Privacy manifest (M-MXA-5): declares the amalgamation's
            // required-reason API usage (stat family → FileTimestamp C617.1,
            // statfs/fstatvfs → DiskSpace E174.1) so Xcode's aggregated
            // privacy report picks it up from the resource bundle.
            resources: [.copy("PrivacyInfo.xcprivacy")],
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
                // Vendored amalgamation, not first-party code: the SQLite/SQLCipher
                // sources trip Apple clang's -Wshorten-64-to-32 (implicit 64→32
                // truncations) and -Wambiguous-macro (MIN/MAX clashing with framework
                // macros) under the macOS 27 SDK — ~125 diagnostics, all inside
                // sqlite3.c. Scoped silence on THIS target only: hand-editing the
                // amalgamation is worse than suppressing warnings we do not own, and
                // there is no behavior change. Owned here (not in each consumer) so
                // path-dep consumers such as Forge inherit a clean build instead of
                // carrying their own local strip. Product and Swift code are
                // unaffected — they still surface all warnings.
                .unsafeFlags([
                    "-Wno-shorten-64-to-32",
                    "-Wno-ambiguous-macro",
                ]),
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
                // NIOSSL: explicit dep to enable TLS context construction in
                // PostgreSQLPool.makeTLSContext(). swift-nio-ssl is already a
                // transitive dependency (PostgresNIO depends on it), so this adds
                // no new external package to the resolved graph — it only makes
                // the existing dep explicit as required by SPM 6 strict mode.
                // (SECFIX-WS2-PK F3 — PostgreSQL TLS planned hardening).
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
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
                // InMemoryStorage: TransactionBoundaryTests contrasts the SQLite
                // transaction seam against the in-memory backend's no-op path.
                "PersistenceKitInMemory",
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
