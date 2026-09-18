// swift-tools-version:6.2
//
// SynapseKit — on-device embedding generation and vector storage.
// Per spec I-4, every stored vector carries the model ID and version
// that produced it. The kit's foundational abstraction is the
// `EmbeddingProvider` protocol; concrete adapters (MiniLM in VEC-03,
// future models) conform to it and storage code remains pluggable.
//
// SynapseKit consumes PersistenceKit's
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
    name: "SynapseKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "SynapseKit", targets: ["SynapseKit"])],
    dependencies: [
        .package(name: "MootProductIdentity", path: "../../libs/MootProductIdentity"),
        .package(name: "EngramLib", path: "../../libs/EngramLib"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // IntellectusLib is the zero-dep telemetry floor. SynapseKit emits
        // search and insert metrics via Intellectus.report(_:), which is a
        // no-op when monitoring is disabled (the default). Off-path cost:
        // one Atomic<Bool> load + branch (~1 ns). No lock on the off-path.
        // Repository-owned dependencies use local package paths.
        .package(name: "IntellectusLib", path: "../../libs/IntellectusLib"),
        // SubstrateKernel: test-only. Int8VecConformanceTests asserts the
        // shared int8 quantisation fixture Tests/Fixtures/encoder/int8_vectors.json
        // against SubstrateKernel.Int8Vec, the producer of the int8 span rows
        // this kit stores. The library target reaches the kernel through
        // SubstrateML and does not depend on it directly.
        .package(path: "../../libs/SubstrateKernel"),
    ],
    targets: [
        .target(
            name: "SynapseKit",
            dependencies: [
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
                "EngramLib",
                "SubstrateTypes", "SubstrateML",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                "IntellectusLib",
            ]
        ),
        .testTarget(
            name: "SynapseKitTests",
            dependencies: [
                "SynapseKit",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                // PersistenceKitSQLite backs the reopen regression test that guards
                // against the dark-recall-on-restart decode bug: only a real
                // on-disk estate exercises the SQLite primitive read-back forms
                // (.text id, .text/ISO8601 filed_at) the in-memory backend does
                // not. Mirrors CorpusKitTests' SQLite dependency.
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                "IntellectusLib",
                "SubstrateKernel",
            ]
        ),
    ]
)
