// swift-tools-version: 6.2
//
// AdornmentLib — dream-time adornment generation and certification.
//
// Provides:
//   - AdornmentValidators: deterministic post-mint validators (AV-1..AV-8
//     golden pins, both ports). The minting model proposes; the validators
//     certify. The model NEVER certifies its own output (architecture ruling,
//     Apple RCA DDE22E7B 2026-08-22).
//   - AdornmentGenerator: the MOOT_MINT_CMD command seam (stdin prompt →
//     stdout claim text) plus the length gate enforced by ADORNMENT_MAX_LENGTH.
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
            path: "Sources/AdornmentLib"
        ),
        .testTarget(
            name: "AdornmentLibTests",
            dependencies: [
                "AdornmentLib",
            ],
            path: "Tests/AdornmentLibTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
