// swift-tools-version:6.2
//
// Installer — the mootx01 unified CLI binary.
//
// Ships a single `mootx01` binary that serves, installs, uninstalls,
// manages named estate databases, and issues queries. The binary
// replaces the prior two-binary arrangement (mootx01-mcp stdio server +
// bash install scripts) per MOOTX01-CLI-001.
//
// The serve subcommand wraps AriaMCP + GeniusLocusKit on macOS only
// (Apple Silicon, macOS 26+). All other subcommands — install, uninstall,
// db, status, query — are cross-platform and compile on Linux.
//
// MootInstallerCore holds path/config helpers and the installer state
// machine. The test target exercises those helpers without spawning a
// process or touching real user data.
//
// Binary name: mootx01 (replaces mootx01-mcp; all client configs use
// the new name after running `mootx01 install`).

import PackageDescription

let package = Package(
    name: "mootx01",
    // macOS(.v26) is the package-level minimum; serve and its deps
    // (AriaMCP, GeniusLocusKit, LocusKit, PersistenceKitSQLite) require it.
    // Linux builds succeed because ServeCommand.swift is guarded with
    // #if os(macOS) — SPM compiles only the cross-platform subcommands
    // (install, uninstall, db, status, query) on Linux.
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MootInstallerCore", targets: ["MootInstallerCore"]),
        .executable(name: "mootx01", targets: ["mootx01"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "AriaLexiconLib", path: "../../packages/libs/AriaLexiconLib"),
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        .package(name: "AriaMcpKit", path: "../../packages/kits/AriaMcpKit"),
        // NeuronKit: DreamCommand constructs DreamingDaemon + seam adapters
        // (EstateDreamingReader, EstateDreamingSink, EstateManifestDreamingPolicyStore)
        // to run one REM-ALPHA dreaming cycle. Required by T10 (ADR-021 Phase 5).
        .package(name: "NeuronKit", path: "../../packages/kits/NeuronKit"),
        // QueueKit: DreamCommand acquires the "dreaming" DrainLease to prevent
        // concurrent dreamers for the same estate. Required by T10 (ADR-021 Phase 5).
        .package(name: "QueueKit", path: "../../packages/kits/QueueKit"),
    ],
    targets: [
        .target(
            name: "MootInstallerCore",
            dependencies: [],
            path: "Sources/MootInstallerCore"
        ),
        .executableTarget(
            name: "mootx01",
            dependencies: [
                "MootInstallerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // macOS-only: serve subcommand depends on the MCP stack + GLK.
                // On Linux these products are unavailable; ServeCommand.swift uses
                // #if os(macOS) guards so the Linux build omits the serve subcommand.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // AriaResident: the shared resident-daemon runner (HTTP transport +
                // autonomic governor + telemetry/monitoring gate). `mootx01 serve` calls it
                // when resident (MOOTX01_HTTP_PORT/--http) so the product binary and
                // aria-mcp run identical resident wiring (ADR-LOOPBACKHTTP-001).
                .product(name: "AriaResident", package: "AriaMcpKit"),
                .product(name: "AriaLexiconLib", package: "AriaLexiconLib"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                // DreamCommand: NeuronKit provides DreamingDaemon + seam adapters;
                // QueueKit provides DrainLease for per-stream stampede prevention.
                .product(name: "NeuronKit", package: "NeuronKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/mootx01"
        ),
        .testTarget(
            name: "MootInstallerCoreTests",
            dependencies: ["MootInstallerCore"],
            path: "Tests/MootInstallerCoreTests"
        ),
    ]
)
