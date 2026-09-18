// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "MootIntentKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MootIntentCore", targets: ["MootIntentCore"]),
    ],
    dependencies: [
        .package(name: "AriaMcpKit", path: "../../kits/AriaMcpKit"),
        .package(name: "QueueKit", path: "../../kits/QueueKit"),
    ],
    targets: [
        .target(
            name: "MootIntentCore",
            dependencies: [
                .product(name: "AriaMCP", package: "AriaMcpKit"),
                .product(name: "QueueKit", package: "QueueKit"),
            ],
            path: "Sources/MootIntentCore"
        ),
        .testTarget(
            name: "MootIntentCoreTests",
            dependencies: [
                "MootIntentCore",
                .product(name: "AriaMCP", package: "AriaMcpKit"),
            ],
            path: "Tests/MootIntentCoreTests"
        ),
    ]
)
