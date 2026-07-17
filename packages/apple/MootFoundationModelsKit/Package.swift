// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "MootFoundationModelsKit",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "MootFoundationModelsKit", targets: ["MootFoundationModelsKit"]),
    ],
    dependencies: [
        .package(name: "MootIntentKit", path: "../MootIntentKit"),
        .package(name: "AriaMcpKit", path: "../../kits/AriaMcpKit"),
        .package(name: "GeniusLocusKit", path: "../../kits/GeniusLocusKit"),
        .package(name: "LocusKit", path: "../../kits/LocusKit"),
        .package(name: "PersistenceKit", path: "../../kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "MootFoundationModelsKit",
            dependencies: [
                .product(name: "MootIntentKit", package: "MootIntentKit"),
                .product(name: "AriaMCP", package: "AriaMcpKit"),
            ]
        ),
        .testTarget(
            name: "MootFoundationModelsKitTests",
            dependencies: [
                "MootFoundationModelsKit",
                .product(name: "MootIntentKit", package: "MootIntentKit"),
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                // The eval suite (Phase 6.6) runs the FM tools against a live
                // in-memory estate — same TestBridge wiring MootIntentKitTests
                // uses (schema → coordinator → dispatcher).
                .product(name: "GeniusLocusKit", package: "GeniusLocusKit"),
                .product(name: "LocusKit", package: "LocusKit"),
                .product(name: "PersistenceKit", package: "PersistenceKit"),
                .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
            ]
        ),
    ]
)
