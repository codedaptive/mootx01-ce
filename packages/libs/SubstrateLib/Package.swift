// swift-tools-version:6.2
//
// Package.swift — SubstrateLib
//
// SubstrateLib is the orchestration layer of the four-package substrate
// split. It
// owns the nine-verb mechanics and the row-state automaton — the control
// surface that composes the three sub-packages — plus the AuditGate write
// gate. The value types live in SubstrateTypes, the hardware-dispatched
// kernels in SubstrateKernel, and the cold-path / ML algorithms in
// SubstrateML; SubstrateLib depends on all three. Each sub-package is a
// direct dependency; callers that need sub-package symbols import them
// separately.
//
// The mathematics across the four packages is conformance-gated. Every
// backend produces bit-identical output to the scalar reference. See
// Tests/SubstrateLibConformanceTests/ for the gate fixtures.
//
// SubstrateLib was promoted from
// docs/engineering/substrate_reference/GeniusLocusReference/
// on 2026-05-19 per current kit ownership.

import PackageDescription

let package = Package(
    name: "SubstrateLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "SubstrateLib",
            targets: ["SubstrateLib"]
        ),
    ],
    dependencies: [
        // The orchestration layer composes all three sub-packages:
        // value types (SubstrateTypes), hardware kernels
        // (SubstrateKernel — AuditGate's bit_field/sha256), and the
        // cold-path / ML algorithms (SubstrateML).
        .package(path: "../SubstrateTypes"),
        .package(path: "../SubstrateKernel"),
        .package(path: "../SubstrateML"),
        // IntellectusLib is the zero-dependency telemetry floor: stat
        // model + StatsSink + Intellectus global holder + short-circuit
        // report gate. It sits BELOW SubstrateLib in the topology
        // (depends on nothing in the repo), so this dependency does not
        // invert layering. Wired here per PACKAGES.md "Mission 2" note
        // and in-repository dependency direction.
        .package(path: "../IntellectusLib"),
    ],
    targets: [
        .target(
            name: "SubstrateLib",
            dependencies: [
                "SubstrateTypes",
                "SubstrateKernel",
                "SubstrateML",
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Sources/SubstrateLib"
        ),
        .testTarget(
            name: "SubstrateLibTests",
            dependencies: [
                "SubstrateLib",
                "SubstrateTypes",
                "SubstrateKernel",
                "SubstrateML",
                .product(name: "IntellectusLib", package: "IntellectusLib"),
            ],
            path: "Tests/SubstrateLibTests"
        ),
        .testTarget(
            name: "SubstrateLibConformanceTests",
            dependencies: [
                "SubstrateLib",
                "SubstrateTypes",
                "SubstrateKernel",
                "SubstrateML",
            ],
            path: "Tests/SubstrateLibConformanceTests"
        ),
    ]
)
