// swift-tools-version:6.2
//
// Package.swift — IntellectusLib
//
// IntellectusLib is the substrate's self-report telemetry faculty.
// It is a zero-dependency LEAF library: it depends on nothing in the
// repo (Foundation only) so that the lowest substrate libs — SubstrateTypes,
// SubstrateKernel, SubstrateLib — can depend on it in a later mission
// without introducing a layering cycle. It becomes the new floor of the
// dependency tree.
//
// What lives here:
//   StatSample     — the telemetry datum (metric or topology event)
//   StatsSink      — protocol for receiving StatSample values
//   NoOpSink       — the default discard implementation
//   Intellectus    — global holder: installed sink + enabled flag
//   report(_:)     — autoclosure short-circuit emission API
//
// What does NOT live here:
//   Any transport, serialization, or observer (later missions).
//   Any substrate primitives (imported by higher kits, not here).
//   Any clock reads — all timestamps are caller-supplied.
//
// Design invariant: when monitoring is disabled (the default), the
// payload autoclosure is NEVER evaluated. The off-path cost is one
// Synchronization.Atomic<Bool> load + branch (~1 ns, lock-free).
// No allocation, no payload construction when disabled.
//
// Platform floor: macOS 26 / iOS 26 (Tahoe). This is the newest
// AI-capable OS as per project policy, and it is required for
// Synchronization.Atomic (available since macOS 15/iOS 18; the .v26
// floor is the project-wide AI-capable OS policy floor).
//
// Consumers that depend on this library:
//   SubstrateTypes, SubstrateKernel, SubstrateLib (in Mission 2)
//   Any kit that needs to emit telemetry at the floor layer.

import PackageDescription

let package = Package(
    name: "IntellectusLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "IntellectusLib",
            targets: ["IntellectusLib"]
        ),
    ],
    // Zero repo dependencies — this is the floor of the tree.
    targets: [
        .target(
            name: "IntellectusLib",
            path: "Sources/IntellectusLib"
        ),
        .testTarget(
            name: "IntellectusLibTests",
            dependencies: ["IntellectusLib"],
            path: "Tests/IntellectusLibTests"
        ),
    ]
)
