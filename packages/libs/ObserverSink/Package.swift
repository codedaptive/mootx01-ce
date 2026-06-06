// swift-tools-version:6.2
//
// Package.swift — ObserverSink
//
// ObserverSink is the reusable PersistenceKit-backed telemetry sink for
// the MOOTx01 manager pipeline (Manager 1.0, Phase 0.5).
//
// What lives here:
//   StatsStore        — SQLite schema, open/migrate, retention.
//   PersistenceStatsSink — StatsSink conformance: serialises each
//                         StatSample into the correct StatsStore table
//                         and honours the global on/off flag row.
//
// Architecture (MANAGER_1.0_PLAN.md §1, §4):
//   - Consumers install PersistenceStatsSink in Intellectus (IntellectusLib).
//   - Each consumer writes its dropbox directly into the shared stats store
//     (SQLite WAL handles concurrent writers; manager owns the store file).
//   - The on/off signal is a flag row in the control table; the sink reads
//     it on each receive() call and short-circuits when monitoring is off.
//
// Dependency hierarchy (no inversion):
//   IntellectusLib (floor) → PersistenceKit (kit) → ObserverSink (this lib)
//
// Dependency additions per DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28:
//   IntellectusLib and PersistenceKit/PersistenceKitSQLite are recorded as
//   MUST_UPDATE items in OBSERVERSINK_001_BLAST_RADIUS.md, citing
//   MANAGER_1.0_PLAN.md §4.
//
// Platform floor: macOS 26 / iOS 26 (Tahoe), matching the project-wide
// AI-capable OS floor and the IntellectusLib/PersistenceKit floors.

import PackageDescription

let package = Package(
    name: "ObserverSink",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "ObserverSink",
            targets: ["ObserverSink"]
        ),
    ],
    dependencies: [
        // IntellectusLib: the StatsSink protocol and StatSample datum.
        // Zero-dep floor library; layering is correct (ObserverSink is downstream).
        .package(path: "../../libs/IntellectusLib"),
        // PersistenceKit: Storage protocol, SchemaDeclaration, RowStore.
        // PersistenceKitSQLite: SQLiteStorage backend.
        // Both are required because the store serialises samples into SQLite.
        .package(path: "../../kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "ObserverSink",
            dependencies: [
                "IntellectusLib",
                "PersistenceKit",
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Sources/ObserverSink"
        ),
        .testTarget(
            name: "ObserverSinkTests",
            dependencies: [
                "ObserverSink",
                "IntellectusLib",
                "PersistenceKit",
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Tests/ObserverSinkTests"
        ),
    ]
)
