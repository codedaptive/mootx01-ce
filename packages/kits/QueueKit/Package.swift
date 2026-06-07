// swift-tools-version:6.2
//
// Package.swift — QueueKit
//
// General-purpose queuing library per docs/canon/QUEUEKIT_SPEC.md.
// Two conforming backends: FilesystemBackend (POSIX maildir) and
// PersistenceKitBackend. Dependencies are limited to SubstrateLib (HLC)
// and PersistenceKit per spec §13. ConvergenceKit is application-layer
// composition and is intentionally NOT a dependency (spec §11).

import PackageDescription

let package = Package(
    name: "QueueKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "QueueKit", targets: ["QueueKit"]),
    ],
    dependencies: [
        .package(path: "../../libs/SubstrateTypes"),
        .package(path: "../PersistenceKit"),
        // ConvergenceKit is NOT listed here — spec §11.
    ],
    targets: [
        .target(
            name: "QueueKit",
            dependencies: [
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
            ]
        ),
        .testTarget(
            name: "QueueKitTests",
            dependencies: [
                "QueueKit",
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
