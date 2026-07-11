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
            ]
        ),
    ]
)
