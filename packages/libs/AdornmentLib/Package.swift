// swift-tools-version: 6.2
//
// AdornmentLib — dream-time adornment generation and certification.
//
// Dark by default under MOOTX01_MINERS. All 13 source files compile only
// when the switch is on. Set the environment variable MOOTX01_MINERS=1
// at build time to enable the library: swift build -Xswiftc -DMOOTX01_MINERS.
//
// Ruling (Encoder Rerank Program, 2026-09-05): adornments did not earn their
// cost at ingest. The library is retained in the tree because its minter
// recipes hold NuExtract for v1.2 KGFact creation. Not deleted — dark.
//
// Design constraints:
//   - Zero external dependencies (C-1 mandate). Pure functions only.
//   - No kit dependencies — pure functions + the command seam. GLK depends
//     on this library; this library does NOT depend on GLK or any kit
//     (layering: AdornmentLib is BELOW GLK in the dependency graph).
//   - No UI code.
//
// Both ports (Swift + Rust) are golden-pinned against the AV-1..AV-8
// fixture. Same inputs, same outputs. Conformance is verified by the
// shared test vectors in each port's test suite.
//
// Platforms: macOS 15 / iOS 18 (Apple Silicon). The Rust port lives at
// rust/ and targets Linux x86_64 and Linux aarch64.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit",
// category "AdornmentLib". Per CLAUDE.md.

import PackageDescription

let miners = Context.environment["MOOTX01_MINERS"].map { !$0.isEmpty } ?? false

let package = Package(
    name: "AdornmentLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "AdornmentLib",
            targets: ["AdornmentLib"]
        ),
    ],
    // Zero external dependencies. No kit deps. Pure functions + command seam.
    dependencies: [],
    targets: [
        .target(
            name: "AdornmentLib",
            // No kit or external deps — the command seam reads a process path
            // from the environment; it does not link any ML library.
            dependencies: [],
            path: "Sources/AdornmentLib",
            swiftSettings: miners
                // MOOTX01_MINERS=1 in the environment: compile the full library.
                ? [.define("MOOTX01_MINERS")]
                // Off by default: the library product exists but exports no
                // symbols. Zero warnings with the switch off.
                : []
        ),
        .testTarget(
            name: "AdornmentLibTests",
            dependencies: [
                "AdornmentLib",
            ],
            path: "Tests/AdornmentLibTests",
            resources: [.copy("Fixtures")],
            swiftSettings: miners ? [.define("MOOTX01_MINERS")] : []
        ),
    ]
)
