// swift-tools-version:6.2
//
// VectorKit — on-device embedding generation and vector storage.
// Per spec I-4, every stored vector carries the model ID and version
// that produced it. The kit's foundational abstraction is the
// `EmbeddingProvider` protocol; concrete adapters (MiniLM in VEC-03,
// future models) conform to it and storage code remains pluggable.
//
// Refactored 2026-05-19 (mission 6): consume PersistenceKit's
// VectorIndex protocol for storage, and SubstrateLib's
// FloatSimHash for the float-to-engram projection. Both changes
// per DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md section 4.6.
//
// VECTORKIT_REPORT_001 (2026-06-06): added IntellectusLib self-report
// telemetry. Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 +
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
        // Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + MANAGER_1.0_PLAN §4.
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
                "IntellectusLib",
            ]
        ),
    ]
)
