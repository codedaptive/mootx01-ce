// swift-tools-version:6.0
//
// CorpusKit -- retrieval-augmented generation storage and retrieval.
// Mission 7 of the eleven-kit graph refactor per
// DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md.
//
// Two targets:
//   CorpusKit           -- core surface (chunkers, BM25, bundle store,
//                       tokenizer protocols, sync manifest)
//   CorpusKitProviders  -- text embedding providers (MiniLM, mpnet,
//                       EmbeddingGemma) and their tokenizers
//
// Providers split out so the core kit stays small. Consumers that
// only need bundle storage and BM25 do not pull in CoreML models.

import PackageDescription

let package = Package(
    name: "CorpusKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CorpusKit", targets: ["CorpusKit"]),
        .library(name: "CorpusKitProviders", targets: ["CorpusKitProviders"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../../libs/SubstrateML"),
        .package(path: "../../libs/EngramLib"),
        .package(path: "../../libs/EideticLib"),
        .package(path: "../PersistenceKit"),
        .package(path: "../ConvergenceKit"),
        .package(path: "../VectorKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CorpusKit",
            dependencies: [
                "SubstrateTypes", "SubstrateML",
                "EngramLib",
                .product(name: "EideticLib", package: "EideticLib"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                "VectorKit",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CorpusKit"
        ),
        .target(
            name: "CorpusKitProviders",
            dependencies: [
                "CorpusKit",
                "SubstrateTypes", "SubstrateML",
                "EngramLib",
                "VectorKit",
            ],
            path: "Sources/CorpusKitProviders"
        ),
        .testTarget(
            name: "CorpusKitTests",
            dependencies: [
                "CorpusKit",
                "CorpusKitProviders",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/CorpusKitTests"
        ),
    ]
)
