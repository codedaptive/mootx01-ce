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
//     HTTP-seam), the host/handoff logic. MootBridge conforms to
//     MootToolCalling (from MootIntentKit) so the intent layer never imports
//     the substrate directly. The lexicon→Apple mapping data.
//   - GatewayUI — the shared SwiftUI surface (model + views) reused by the
//     macOS and iOS app targets (built via the xcodegen project here).
//
// The intent surface (App Intents, Shortcuts, callback-URL, Share Sheet) lives
// in MootIntentKit at packages/apple/MootIntentKit — consumed here by MootGateway.
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
    name: "Mootx01-App",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MootGateway", targets: ["MootGateway"]),
        .library(name: "GatewayUI", targets: ["GatewayUI"]),
    ],
    dependencies: [
        .package(name: "AriaMcpKit", path: "../../packages/kits/AriaMcpKit"),
        .package(name: "GeniusLocusKit", path: "../../packages/kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../packages/kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../packages/kits/PersistenceKit"),
        // MootIntentKit owns the intent surface; MootBridge conforms to its
        // MootToolCalling protocol so the kit never reaches substrate internals.
        .package(name: "MootIntentKit", path: "../../packages/apple/MootIntentKit"),
    ],
    targets: [
        .target(
            name: "MootGateway",
            dependencies: [
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
                .product(name: "PersistenceKitSQLite", package: "PersistenceKit"),
                .product(name: "MootIntentKit", package: "MootIntentKit"),
            ],
            path: "Sources/MootGateway"
        ),
        .target(
            name: "GatewayUI",
            dependencies: [
                "MootGateway",
                .product(name: "MootIntentKit", package: "MootIntentKit"),
            ],
            path: "Sources/GatewayUI"
        ),
        .testTarget(
            name: "MootGatewayTests",
            dependencies: [
                "MootGateway",
                .product(name: "MootIntentKit", package: "MootIntentKit"),
                // A2 integration tests start the real ARIA HTTP server in-process
                // (HTTPServer from AriaMCP) to verify HTTPTransport against the live
                // wire. These are the only imports beyond MootGateway in the test
                // target; they are unavoidable for the in-process server harness.
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/MootGatewayTests"
        ),
        // A-4: unit tests for AppModel.lastLoggedID() — verifies the capture-log
        // UUID parse without needing a live bridge (intentRunLog is populated
        // directly). GatewayUI is a SwiftUI layer so this target is macOS-only;
        // the function under test has no platform-specific behavior.
        .testTarget(
            name: "GatewayUITests",
            dependencies: [
                "GatewayUI",
                "MootGateway",
                .product(name: "MootIntentKit", package: "MootIntentKit"),
            ],
            path: "Tests/GatewayUITests"
        ),
    ]
)
