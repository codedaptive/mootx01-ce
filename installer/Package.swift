// swift-tools-version:6.0
//
// Installer — the LAUNCH-05 installer and first-run binary.
//
// Ships the `mootx01-mcp` stdio MCP server that the installer wires
// into Claude Desktop, Claude Code, and other MCP clients. The binary
// wraps the public AriaMCP library (ARIA_MCP/Sources/AriaMCP) on top
// of a persistent SQLite-backed GeniusLocusKit estate stored under
// the user's data directory. First-run is a code path inside the
// same binary: when the estate file is absent it calls
// LocusKit.Estate.create on the MDCC default before serving.
//
// The bare `aria-mcp` executable in ARIA_MCP/ is the in-memory
// LAUNCH-04 transactional spike and is left untouched. mootx01-mcp
// is the user-installed binary; it consumes only published AriaMCP,
// GeniusLocusKit, LocusKit, and PersistenceKitSQLite API.
//
// MootInstallerCore holds the path-and-config helpers used by both
// the executable and the installer's test target so platform-path
// logic can be exercised without spawning a process.
//
// Platforms: macOS 15 (Apple Silicon). Monday targets macOS only
// per docs/canon/LAUNCH_PLAN.md §"The Monday cut"; install.sh exits
// gracefully on other platforms.

import PackageDescription

let package = Package(
    name: "Installer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MootInstallerCore", targets: ["MootInstallerCore"]),
        .executable(name: "mootx01-mcp", targets: ["mootx01-mcp"]),
    ],
    dependencies: [
        .package(name: "AriaLexicon", path: "../AriaLexicon"),
        .package(name: "GeniusLocusKit", path: "../GeniusLocusKit"),
        .package(name: "LocusKit", path: "../LocusKit"),
        .package(name: "PersistenceKit", path: "../PersistenceKit"),
        .package(name: "ARIA_MCP", path: "../ARIA_MCP"),
    ],
    targets: [
        .target(
            name: "MootInstallerCore",
            dependencies: [],
            path: "Sources/MootInstallerCore"
        ),
        .executableTarget(
            name: "mootx01-mcp",
            dependencies: [
                "MootInstallerCore",
                .product(name: "AriaMCP", package: "ARIA_MCP"),
                .product(name: "AriaLexicon", package: "AriaLexicon"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Sources/mootx01-mcp"
        ),
        .testTarget(
            name: "MootInstallerCoreTests",
            dependencies: ["MootInstallerCore"],
            path: "Tests/MootInstallerCoreTests"
        ),
    ]
)
