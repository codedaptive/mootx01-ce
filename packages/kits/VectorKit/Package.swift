// swift-tools-version:6.2
//
// VectorKit — on-device embedding generation and vector storage.
// Per spec I-4, every stored vector carries the model ID and version
// that produced it. The kit's foundational abstraction is the
// `EmbeddingProvider` protocol; concrete adapters (MiniLM in VEC-03,
// future models) conform to it and storage code remains pluggable.
//
// VectorKit consumes PersistenceKit's
// VectorIndex protocol for storage, and SubstrateLib's
// FloatSimHash for the float-to-engram projection. Both changes
// and keeps storage ownership outside this package.
//
// VECTORKIT_REPORT_001 (2026-06-06): added IntellectusLib self-report
// telemetry. Authority: in-repository dependency direction +
// MANAGER_1.0_PLAN §4 (P2 self-report coverage). Layering: IntellectusLib
// has zero repo deps; adding it here is strictly downstream→upstream,
// no cycle.

import PackageDescription

let package = Package(
    name: "VectorKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "VectorKit", targets: ["VectorKit"])],
    dependencies: [
        .package(name: "EngramLib", path: "../../libs/EngramLib"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // IntellectusLib is the zero-dep telemetry floor. VectorKit emits
        // search and insert metrics via Intellectus.report(_:), which is a
        // no-op when monitoring is disabled (the default). Off-path cost:
        // one Atomic<Bool> load + branch (~1 ns). No lock on the off-path.
        // Repository-owned dependencies use local package paths.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
    ],
    targets: [
        .target(
            name: "VectorKit",
            dependencies: [
                "EngramLib",
                "SubstrateTypes", "SubstrateML",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                "IntellectusLib",
            ]
        ),
        .testTarget(
            name: "VectorKitTests",
            dependencies: [
                "VectorKit",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitSQLite backs the reopen regression test that guards
                // against the dark-recall-on-restart decode bug: only a real
                // on-disk estate exercises the SQLite primitive read-back forms
                // (.text id, .text/ISO8601 filed_at) the in-memory backend does
                // not. Mirrors CorpusKitTests' SQLite dependency.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                "IntellectusLib",
            ]
        ),
    ]
)
