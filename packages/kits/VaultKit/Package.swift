// swift-tools-version:6.2
//
// VaultKit — bidirectional bridge between a MOOT estate and a
// human-readable Markdown vault (Obsidian as the first adapter).
//
// VaultKit inverts Karpathy's "LLM maintains a Markdown wiki" pattern:
// the substrate stays authoritative, and the vault is a projection
// (export) or an external source (import). The substrate is never the
// wiki.
//
// Layering: VaultKit sits ABOVE GeniusLocusKit (the verb/composition
// layer). It consumes the GLK verb surface (`capture`, `recall`,
// `recallTunnels`, `estate(for:)`) and LocusKit value types through
// their public products only — it modifies no substrate primitive,
// schema, bitmap, or enum. FDC classification on import is a soft,
// feature-flagged dependency on EideticLib: when `lookup` resolves, the
// live FDC anchor is used; otherwise the deterministic fallback UDC
// "000" lands the drawer with provenance intact (no fakery either way).
//
// `NoteIR` and the pure mapping functions are written port-cleanly
// (Codable, flat field names, no Swift-only platform deps in the
// mapping path). The Rust parallel lives in `rust/` (crate `vault-kit`);
// SwiftPM does not build it — `cargo test` in `rust/` is the Rust leg.
//
// Platforms: macOS 15 / iOS 18 (Apple Silicon), matching GeniusLocusKit.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category
// "VaultKit". Per CLAUDE.md.

import PackageDescription

let package = Package(
    name: "VaultKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "VaultKit",
            targets: ["VaultKit"]
        ),
    ],
    dependencies: [
        .package(name: "GeniusLocusKit", path: "../GeniusLocusKit"),
        .package(name: "LocusKit", path: "../LocusKit"),
        .package(name: "EideticLib", path: "../../libs/EideticLib"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        // QueueKit: the outbound MemPalace pump (PalacePump.swift) uses the
        // queue as its checkpoint + pacing layer — each note becomes a job, so
        // a crash mid-pump resumes from the queue rather than from zero
        // (DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28, cited in this mission's
        // Blast Radius Report). Layering: VaultKit (above GLK) → QueueKit (kit
        // layer); no inversion.
        .package(name: "QueueKit", path: "../QueueKit"),
    ],
    targets: [
        .target(
            name: "VaultKit",
            dependencies: [
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "EideticLib", package: "EideticLib"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/VaultKit"
        ),
        .testTarget(
            name: "VaultKitTests",
            dependencies: [
                "VaultKit",
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Tests/VaultKitTests"
        ),
    ]
)
