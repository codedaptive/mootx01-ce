// swift-tools-version:6.2
//
// Package.swift — ConvergenceKit
//
// ConvergenceKit replicates PersistenceKit operations across device or
// perimeter boundaries. Backends at v1.0: CloudKit (Apple
// ecosystem), Federation (substrate-native CRDT exchange),
// None (single-device passthrough).
//
// Design per the ConvergenceKit replication surface.
// Eleven-kit graph per current kit ownership.

import PackageDescription

let package = Package(
    name: "ConvergenceKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "ConvergenceKit", targets: ["ConvergenceKit"]),
        .library(name: "ConvergenceKitNone", targets: ["ConvergenceKitNone"]),
        .library(name: "ConvergenceKitCloudKit", targets: ["ConvergenceKitCloudKit"]),
        .library(name: "ConvergenceKitFederation", targets: ["ConvergenceKitFederation"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../PersistenceKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        // Core protocols + types.
        .target(
            name: "ConvergenceKit",
            dependencies: [
                "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/ConvergenceKit"
        ),

        // Backends.
        .target(
            name: "ConvergenceKitNone",
            dependencies: [
                "ConvergenceKit",
                "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/ConvergenceKitNone"
        ),
        .target(
            name: "ConvergenceKitCloudKit",
            dependencies: [
                "ConvergenceKit",
                "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ],
            path: "Sources/ConvergenceKitCloudKit"
        ),
        .target(
            name: "ConvergenceKitFederation",
            dependencies: [
                "ConvergenceKit",
                "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ConvergenceKitFederation"
        ),

        // Conformance fixture library (reused by every backend's test target).
        .target(
            name: "ConvergenceKitConformance",
            dependencies: [
                "ConvergenceKit",
                "SubstrateTypes",
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/ConvergenceKitConformance"
        ),

        // Test targets.
        .testTarget(
            name: "ConvergenceKitTests",
            dependencies: [
                "ConvergenceKit",
                "SubstrateTypes",
                // SkewQueueTests uses InMemoryStorage to exercise PendingSkewQueue
                // and SkewReplay in isolation (CVK-ICLOUD P3-M4).
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/ConvergenceKitTests"
        ),
        .testTarget(
            name: "ConvergenceKitNoneTests",
            dependencies: [
                "ConvergenceKit",
                "ConvergenceKitNone",
                "ConvergenceKitConformance",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/ConvergenceKitNoneTests"
        ),
        .testTarget(
            name: "ConvergenceKitCloudKitTests",
            dependencies: [
                "ConvergenceKit",
                "ConvergenceKitCloudKit",
                "ConvergenceKitConformance",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/ConvergenceKitCloudKitTests"
        ),
        .testTarget(
            name: "ConvergenceKitFederationTests",
            dependencies: [
                "ConvergenceKit",
                "ConvergenceKitFederation",
                // P5-M1b: needed to call CKSideSchema.ensure in retention tests that
                // verify OutboxStore.deleteMatchingParked works when the CK outbox table
                // exists on a storage instance also used by the Federation backend.
                "ConvergenceKitCloudKit",
                "ConvergenceKitConformance",
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/ConvergenceKitFederationTests"
        ),
    ]
)
