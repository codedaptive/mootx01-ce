// swift-tools-version:6.0
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

import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"]),
        .library(name: "PersistenceKitInMemory", targets: ["PersistenceKitInMemory"]),
        .library(name: "PersistenceKitSQLite", targets: ["PersistenceKitSQLite"]),
        .library(name: "PersistenceKitPostgreSQL", targets: ["PersistenceKitPostgreSQL"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateLib"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
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
            dependencies: ["SubstrateLib", "SubstrateTypes"],
            path: "Sources/PersistenceKit"
        ),

        // Backends.
        .target(
            name: "PersistenceKitInMemory",
            dependencies: ["PersistenceKit", "SubstrateLib", "SubstrateTypes"],
            path: "Sources/PersistenceKitInMemory"
        ),
        .target(
            name: "PersistenceKitSQLite",
            dependencies: ["PersistenceKit", "SubstrateLib", "SubstrateTypes", "CSQLiteVec"],
            path: "Sources/PersistenceKitSQLite"
        ),
        .target(
            name: "PersistenceKitPostgreSQL",
            dependencies: [
                "PersistenceKit",
                "SubstrateLib", "SubstrateTypes",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Sources/PersistenceKitPostgreSQL"
        ),

        // Tests.
        .testTarget(
            name: "PersistenceKitTests",
            dependencies: ["PersistenceKit", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitTests"
        ),
        .target(
            name: "PersistenceKitConformance",
            dependencies: ["PersistenceKit", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitConformance"
        ),
        .testTarget(
            name: "PersistenceKitConformanceTests",
            dependencies: ["PersistenceKit", "PersistenceKitConformance", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitConformanceTests"
        ),
        .testTarget(
            name: "PersistenceKitInMemoryTests",
            dependencies: ["PersistenceKit", "PersistenceKitInMemory", "PersistenceKitConformance", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitInMemoryTests"
        ),
        .testTarget(
            name: "PersistenceKitSQLiteTests",
            dependencies: ["PersistenceKit", "PersistenceKitSQLite", "PersistenceKitConformance", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitSQLiteTests"
        ),
        .testTarget(
            name: "PersistenceKitPostgreSQLTests",
            dependencies: ["PersistenceKit", "PersistenceKitPostgreSQL", "PersistenceKitConformance", "SubstrateLib", "SubstrateTypes"],
            path: "Tests/PersistenceKitPostgreSQLTests"
        ),
    ]
)
