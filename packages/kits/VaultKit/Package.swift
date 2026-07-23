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
// Platforms: macOS 26 / iOS 26, matching GeniusLocusKit.
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
        // (in-repository dependency direction, cited in this mission's
        // Blast Radius Report). Layering: VaultKit (above GLK) → QueueKit (kit
        // layer); no inversion.
        .package(name: "QueueKit", path: "../QueueKit"),
        // CorpusKit: TEST-ONLY dep added for the Part B encode-enqueue test
        // (secfix/c-vault-export2). The test must call kit.provision() with
        // EmbeddingModel.deterministic to mount a Corpus so reindexMissing
        // can return > 0 after a bulk import. Without a Corpus the test can
        // only assert the no-Corpus path (returns 0), which does not verify
        // the encode-enqueue behaviour. Layering: VaultKit sits above GLK;
        // GLK already depends on CorpusKit — this adds the direct test dep
        // so VaultKitTests can name the type. No production code in VaultKit
        // imports CorpusKit; the dep is test-target-only.
        .package(name: "CorpusKit", path: "../CorpusKit"),
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
                // CorpusKit: needed to name EmbeddingModel.deterministic in the
                // Part B encode-enqueue test (secfix/c-vault-export2).
                .product(name: "CorpusKit", package: "CorpusKit"),
            ],
            path: "Tests/VaultKitTests"
        ),
    ]
)
