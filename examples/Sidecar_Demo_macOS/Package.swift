// swift-tools-version:6.0
//
// Sidecar_Demo_macOS — the headline sidecar demonstration.
//
// This package is one demo, two targets. The point is to show, in the
// smallest possible amount of code, the sidecar pattern named in
// docs/canon/MOOTX01_AND_ARIA_CANON.md §"The sidecar pattern":
//
//   An existing app attaches a MOOT alongside itself and opens that
//   knowledge to the organization through the ARIA_MCP server, so any
//   MCP client can reach it. The app is not rebuilt on the SDK; it
//   gains a MOOT beside it and exposes that memory over MCP.
//
// The two targets:
//
//   1. SidecarDemoApp (library) — the `MootSidecar` attachment object.
//      A host application creates one of these, hands it a backend, and
//      reads `dispatcher` and `handle` back out. The library is the
//      ~50 lines of glue an existing app would copy into its own source
//      to gain a MOOT.
//
//   2. sidecar-demo (executable) — a thin entry point that constructs
//      a `MootSidecar` and runs the ARIA_MCP stdio loop over the
//      sidecar's dispatcher. Run this binary and any MCP client (Claude
//      Desktop, Claude Code, MemPalace, the `mcp` CLI) can reach the
//      attached MOOT.
//
// Dependencies are listed as sibling-package paths because every kit in
// this repository is published the same way (see ARIA_MCP/Package.swift).
// QueueKit, VectorKit, CorpusKit are transitive through GeniusLocusKit and
// are intentionally NOT listed here; adding them would only create
// version-resolution noise.
//
// PersistenceKitInMemory is a separate named product on the PersistenceKit
// package (see PersistenceKit/Package.swift). It must be listed explicitly
// because PersistenceKit's default library product does not bundle it.
//
// Platforms: macOS 15+ / iOS 18+ — same floor as ARIA_MCP and the rest
// of the kit stack. The "macOS" in the package name reflects the demo's
// home; nothing in the code is macOS-only.

import PackageDescription

let package = Package(
    name: "Sidecar_Demo_macOS",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "SidecarDemoApp", targets: ["SidecarDemoApp"]),
        .executable(name: "sidecar-demo", targets: ["sidecar-demo"]),
    ],
    dependencies: [
        .package(name: "ARIA_MCP", path: "../../apps/ARIA_MCP"),
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "SidecarDemoApp",
            dependencies: [
                .product(name: "AriaMCP", package: "ARIA_MCP"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Sources/SidecarDemoApp"
        ),
        .executableTarget(
            name: "sidecar-demo",
            dependencies: [
                "SidecarDemoApp",
                .product(name: "AriaMCP", package: "ARIA_MCP"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Sources/sidecar-demo"
        ),
        .testTarget(
            name: "SidecarDemoAppTests",
            dependencies: [
                "SidecarDemoApp",
                .product(name: "AriaMCP", package: "ARIA_MCP"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/SidecarDemoAppTests"
        ),
    ]
)
