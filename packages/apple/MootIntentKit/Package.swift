// swift-tools-version:6.2
//
// MootIntentKit — Apple-only intent surface for MOOTx01.
//
// Placement: packages/apple/ — above the platform-neutral kit stack (parity
// line), Apple-only, no Rust twin required. This is the iOS/iPadOS-native
// equivalent of the MCP server surface: it exposes the six caller-driven ARIA
// verbs through App Intents, Shortcuts, callback-URL routing, and the Share
// Sheet capture sink. The engine packages (GeniusLocusKit, LocusKit, etc.)
// are never imported here; the seam is the MootToolCalling protocol that
// MootBridge (in apps/Mootx01-App) conforms to.
//
// Why packages/apple/ and not apps/Mootx01-App/Sources/?
//   apps/Mootx01-App is the host app, which wires MootBridge (substrate-touching)
//   to the runtime. Intent code must be reusable without pulling in substrate
//   internals. Placing MootIntentKit in packages/apple/ gives it a clean home
//   that other Apple host apps (examples, future CE app) can consume without
//   replicating the intent logic.
//
// Platforms: macOS 26 / iOS 26 (Apple Silicon), matching the kit stack.

import PackageDescription

let package = Package(
    name: "MootIntentKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MootIntentKit", targets: ["MootIntentKit"]),
    ],
    // Package-level dependencies: ARIA_MCP for JSONValue / dispatcher types;
    // the substrate kits are test-only (pulled in by the test target only).
    // Listed at package level because SPM requires all package refs here.
    dependencies: [
        .package(name: "AriaMcpKit", path: "../../kits/AriaMcpKit"),
        .package(name: "GeniusLocusKit", path: "../../kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "MootIntentKit",
            // No dependency on substrate kits. The seam is MootToolCalling —
            // a protocol defined in this package that MootBridge conforms to.
            // AriaMCP is the only inter-package import because JSONValue is the
            // tool-argument type the intents build.
            dependencies: [
                .product(name: "AriaMCP", package: "AriaMcpKit"),
            ],
            path: "Sources/MootIntentKit"
        ),
        .testTarget(
            name: "MootIntentKitTests",
            dependencies: [
                "MootIntentKit",
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // GeniusLocusKit and friends are pulled in here so the test
                // target can build a real MootBridge conformance and exercise
                // the tool-call composition functions against a live in-memory
                // estate.
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ],
            path: "Tests/MootIntentKitTests"
        ),
    ]
)
