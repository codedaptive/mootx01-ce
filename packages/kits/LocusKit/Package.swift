// swift-tools-version: 6.0
// LocusKit — Loci databases for MOOTx01.
//
// Apple Silicon only (macOS 15 / iOS 18). Storage is provided by
// PersistenceKit: LocusKit declares its schema in PersistenceKit primitives
// and persists through the Storage protocol rather than the raw
// SQLite3 C API. The concrete backend (SQLite or in-memory) is
// injected by the caller; tests use both. Logging uses Apple OSLog
// with the fleet subsystem "com.mootx01.kit".
//
// LocusKit composes — it does not inherit. DrawerStore is the public
// actor surface over the storage primitives: drawer/tunnel/diary/
// kg_fact value types, the LocusKitError enum, the LocusKitSchema
// declaration, and the actor itself.
//
// Embedding generation, vector retrieval, the search pipeline, the
// directory walker, and the MCP server are out of scope here and
// ship in subsequent LOCI-* missions.

import PackageDescription

let package = Package(
    name: "LocusKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "LocusKit",
            targets: ["LocusKit"]
        ),
    ],
    dependencies: [
        .package(name: "SubstrateLib", path: "../../libs/SubstrateLib"),
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../../libs/SubstrateKernel"),
        .package(path: "../../libs/SubstrateML"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
    ],
    targets: [
        .target(
            name: "LocusKit",
            dependencies: [
                .product(name: "SubstrateLib", package: "SubstrateLib"),
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "SubstrateKernel", package: "SubstrateKernel"),
                .product(name: "SubstrateML", package: "SubstrateML"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/LocusKit"
        ),
        .testTarget(
            name: "LocusKitTests",
            dependencies: [
                "LocusKit",
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/LocusKitTests"
        ),
    ]
)
