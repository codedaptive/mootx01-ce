// swift-tools-version:6.0
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

import PackageDescription

let package = Package(
    name: "VectorKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "VectorKit", targets: ["VectorKit"])],
    dependencies: [
        .package(name: "EngramLib", path: "../../libs/EngramLib"),
        .package(name: "SubstrateLib", path: "../../libs/SubstrateLib"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
    ],
    targets: [
        .target(
            name: "VectorKit",
            dependencies: [
                "EngramLib",
                "SubstrateLib", "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ]
        ),
        .testTarget(
            name: "VectorKitTests",
            dependencies: [
                "VectorKit",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ]
        ),
    ]
)
