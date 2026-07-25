// swift-tools-version:6.2
//
// Mootx01 — the Apple presentation layer over the clean MOOTx01 engine.
//
// This SwiftPM package vends the two Swift-only, Apple-side libraries the
// Mootx01 app (and the developer example apps) build on. It is the "Apple
// layer" of the app/engine boundary: it ENVELOPES the clean, Rust-mirrored engine through a
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
// Platforms: macOS 27 / iOS 27 (Apple Silicon) — the app leads the kit stack
// here deliberately (Bob ruling 2026-07-07, estate F76F97BC): the WWDC26
// adoption path (App Intents 2027 wave, Core AI, SpotlightSearchTool) is 27+.
// Relative paths are ../../ — this package lives in apps/, siblings of packages/.

import PackageDescription

let package = Package(
    name: "Mootx01-App",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
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
        .package(name: "MootFoundationModelsKit", path: "../../packages/apple/MootFoundationModelsKit"),
        // Sync lives in ConvergenceKit (CloudKitSyncEngine / NoSyncEngine behind
        // the SyncEngine protocol) — the app wires it, it does not reimplement it.
        .package(name: "ConvergenceKit", path: "../../packages/kits/ConvergenceKit"),
        .package(name: "WorkPacketKit", path: "../../packages/kits/WorkPacketKit"),
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
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                .product(name: "ConvergenceKitCloudKit", package: "ConvergenceKit"),
                // FED-OD-3: QR pairing ceremony uses ConvergenceKitFederation types
                // (PairingProposal, PairingAcceptance, HyperplaneFamilySpec, etc.)
                .product(name: "ConvergenceKitFederation", package: "ConvergenceKit"),
            ],
            path: "Sources/MootGateway"
        ),
        .target(
            name: "GatewayUI",
            dependencies: [
                "MootGateway",
                .product(name: "MootIntentKit", package: "MootIntentKit"),
                .product(name: "MootFoundationModelsKit", package: "MootFoundationModelsKit"),
                // FED-OD-3: QR pairing views reference ConvergenceKitFederation types
                // (LocalIdentity, HyperplaneFamilySpec) passed in from the app layer.
                .product(name: "ConvergenceKitFederation", package: "ConvergenceKit"),
                // FAB5-I3: PacketListView, PacketDetailView, LineageView consume
                // WorkPacket, WorkPacketStore, LineageGraph.
                .product(name: "WorkPacketKit", package: "WorkPacketKit"),
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
                .product(name: "ConvergenceKit", package: "ConvergenceKit"),
                .product(name: "ConvergenceKitNone", package: "ConvergenceKit"),
                // P5-M2 push nudge tests: need @testable access to
                // CloudKitSyncEngine.cloudKitZoneName (internal method).
                .product(name: "ConvergenceKitCloudKit", package: "ConvergenceKit"),
                // FED-OD-3: QR pairing ceremony tests use ConvergenceKitFederation types.
                .product(name: "ConvergenceKitFederation", package: "ConvergenceKit"),
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
                // FAB5-I3: PacketViewsTests constructs WorkPacket fixtures directly.
                .product(name: "WorkPacketKit", package: "WorkPacketKit"),
            ],
            path: "Tests/GatewayUITests"
        ),
    ]
)
