// swift-tools-version:6.2
import PackageDescription

// Standalone benchmarking tool. JSON config decodes via Foundation Codable —
// no YAML parser needed. The tool speaks the MCP wire protocol to the two
// servers it benchmarks; it imports no MOOTx01 kit at the MCP boundary.
// External dependency: `swift-subprocess` (for stdio process management).
//
// In-repo library dependencies are recorded as MUST_UPDATE in
// BENCHMARKER_001_BLAST_RADIUS.md: the benchmarker
// emits its real metrics through IntellectusLib into ObserverSink's
// PersistenceStatsSink (the `--stats-store` option). Layering is correct
// (the tool is downstream of both libs).
//
// Platform floor: macOS 26 (Tahoe) / swift-tools 6.2 — matches the
// IntellectusLib / ObserverSink floors this tool now depends on, and the
// project-wide AI-capable OS floor.
//
// This package lives at benchmarks/, a direct child of the repository root.
// Package-relative dependency paths below are resolved from there.
let package = Package(
    name: "mcp-benchmarker",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "mcp-benchmarker", targets: ["benchmarker-bin"]),
        // The core library surface that extension subpackages build on. Core
        // depends on no extension; this package builds standalone.
        .library(name: "BenchmarkerCore", targets: ["mcp-benchmarker"]),
    ],
    dependencies: [
        .package(path: "../packages/libs/IntellectusLib"),
        .package(path: "../packages/libs/ObserverSink"),
        // EstateEncryption: the plaintext-to-encrypted conversion, shared with
        // the product. The matrix benchmark converts a copy of a prebuilt
        // database; the conversion itself is not measured.
        .package(path: "../packages/libs/EstateEncryption"),
        // Apple's Subprocess package — the supported way to drive a child
        // process's stdio. Foundation's Process+Pipe+FileHandle path carries a
        // documented ~150-200ms per-call read-wakeup latency on macOS that
        // falsified the gauntlet's per-call latency measurement; Apple's own
        // guidance (Developer Forums 690310) is to adopt Subprocess. This is a
        // TOOL dependency only — no kit takes it; the kit zero-external-dep
        // rule is unaffected.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
        // MootProductIdentity: canonical platform-specific configuration directory.
        // Used by ScratchPosture.swift to guard against serving a live registered
        // estate as a benchmark target; the harness must use the same directory rule
        // the product uses so the guard fires on the real path (macOS Application
        // Support, Linux XDG data dir). Harness is downstream of all kits; layering
        // is correct.
        .package(path: "../packages/libs/MootProductIdentity"),
    ],
    targets: [
        // The core library: engine, adapters, runners, reporting, CLI logic.
        // A library (not an executable) so extension subpackages and the
        // thin executable shell both build on the same module.
        .target(
            name: "mcp-benchmarker",
            dependencies: [
                "IntellectusLib",
                "ObserverSink",
                // The conversion the product performs, so the matrix benchmark
                // measures that one rather than a copy of it.
                .product(name: "EstateEncryption", package: "EstateEncryption"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                // Product configuration directory — same path rule as the binary
                // the harness drives; required by the registered-path guard in
                // ScratchPosture.swift.
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
            ],
            path: "Sources/mcp-benchmarker"
        ),
        // Thin executable shell: forwards CommandLine.arguments into the
        // library's `benchmarkerMain`.
        .executableTarget(
            name: "benchmarker-bin",
            dependencies: ["mcp-benchmarker"],
            path: "Sources/benchmarker-bin"
        ),
        .testTarget(
            name: "mcp-benchmarkerTests",
            dependencies: [
                "mcp-benchmarker",
                // MootProductIdentity imported directly in ScratchPostureTests to
                // pin test fixtures against the same source the production code uses.
                .product(name: "MootProductIdentity", package: "MootProductIdentity"),
            ],
            path: "Tests/mcp-benchmarkerTests",
            // Hand-authored fixtures the tests read by path relative to
            // #filePath; they are not bundle resources.
            exclude: [
                "artifact_rust_written.json",
                "lme_spec_sample.json",
                "lmeb_sample",
                "locomo_sample.json",
                "locomo_spec_sample.json",
                "longmemeval_sample.json",
                "membench_sample.json",
            ]
        ),
    ]
)
