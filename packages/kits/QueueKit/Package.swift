// swift-tools-version:6.2
//
// Package.swift — QueueKit
//
// General-purpose queuing library.
// Two conforming backends: FilesystemBackend (POSIX maildir) and
// PersistenceKitBackend. Dependencies: SubstrateTypes (HLC), PersistenceKit
// and IntellectusLib supplies self-report telemetry.
// ConvergenceKit is application-layer composition and is intentionally NOT a
// dependency.

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
        // IntellectusLib: self-report telemetry via QueueKitTelemetry.swift
        //. Lib-layer dependency;
        // layering does not invert.
        .package(path: "../../libs/IntellectusLib"),
        // ConvergenceKit is NOT listed here — spec §11.
    ],
    targets: [
        .target(
            name: "QueueKit",
            dependencies: [
                .product(name: "SubstrateTypes", package: "SubstrateTypes"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "IntellectusLib", package: "IntellectusLib"),
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
