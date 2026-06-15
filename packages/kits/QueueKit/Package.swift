// swift-tools-version:6.2
//
// Package.swift — QueueKit
//
// General-purpose queuing library per docs/canon/QUEUEKIT_SPEC.md.
// Two conforming backends: FilesystemBackend (POSIX maildir) and
// PersistenceKitBackend. Dependencies: SubstrateTypes (HLC), PersistenceKit
// (spec §13), IntellectusLib (self-report telemetry, DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28).
// ConvergenceKit is application-layer composition and is intentionally NOT a
// dependency (spec §11).

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
        // (DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28). Lib-layer dependency;
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
