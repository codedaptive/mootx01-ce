// swift-tools-version:6.2
//
// Mootx01 — the Apple presentation layer over the clean MOOTx01 engine.
//
// This SwiftPM package vends the two Swift-only, Apple-side libraries the
// Mootx01 app (and the developer example apps) build on. It is the "Apple
// layer" of ADR-005: it ENVELOPES the clean, Rust-mirrored engine through a
// transport seam — it never absorbs it. The headless `mootx01`/`aria-mcp`
// server is a separate, untouched binary.
//
//   - MootGateway — the substrate-facing bridge: MootBridge (drives the ARIA
//     tool surface), the transport modes (embedded / managed-subprocess /
//     HTTP-seam), the host/handoff logic, and the App Intent / Shortcuts /
//     callback-URL / share-sink shells. The lexicon→Apple mapping data.
//   - GatewayUI — the shared SwiftUI surface (model + views) reused by the
//     macOS and iOS app targets (built via the xcodegen project here).
//
// The runnable app targets live in the Xcode project (project.yml → xcodegen)
// because real, system-registered App Intents require an app bundle. This
// package has no executable target; `swift build`/`swift test` exercise the
// libraries headlessly.
//
// Platforms: macOS 26 / iOS 26 (Apple Silicon), matching the kit stack.
// Relative paths are ../../ — this package lives in apps/, siblings of packages/.

import PackageDescription

let package = Package(
    name: "Mootx01",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MootGateway", targets: ["MootGateway"]),
        .library(name: "GatewayUI", targets: ["GatewayUI"]),
    ],
    dependencies: [
        .package(name: "ARIA_MCP", path: "../../apps/ARIA_MCP"),
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "MootGateway",
            dependencies: [
                .product(name: "AriaMCP", package: "ARIA_MCP"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
            ],
            path: "Sources/MootGateway"
        ),
        .target(
            name: "GatewayUI",
            dependencies: ["MootGateway"],
            path: "Sources/GatewayUI"
        ),
        .testTarget(
            name: "MootGatewayTests",
            dependencies: ["MootGateway"],
            path: "Tests/MootGatewayTests"
        ),
    ]
)
