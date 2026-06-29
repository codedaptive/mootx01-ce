// swift-tools-version:6.2
//
// Mootx01-Setup — post-install setup assistant for the macOS .pkg installer.
//
// A minimal single-window SwiftUI app that detects installed MCP clients,
// lets the user select which ones to wire, and runs the install. Launched by
// the .pkg postinstall script; also usable standalone.
//
// Model layer is MootInstallerCore (from apps/mootx01), which already has
// the full client registry, detection, and config-merge engine with zero
// external dependencies. This app is a thin SwiftUI projection of that API.

import PackageDescription

let package = Package(
    name: "Mootx01-Setup",
    // Platform floor matches apps/mootx01 (MootInstallerCore lives in that
    // package and inherits its platform constraint).
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(name: "mootx01", path: "../mootx01"),
    ],
    targets: [
        .executableTarget(
            name: "Mootx01Setup",
            dependencies: [
                .product(name: "MootInstallerCore", package: "mootx01"),
            ],
            path: "Sources/Mootx01Setup"
        ),
    ]
)
