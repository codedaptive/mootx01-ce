// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "Mootx01-App",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MootCommunityGateway", targets: ["MootCommunityGateway"]),
        .library(name: "MootCommunityUI", targets: ["MootCommunityUI"]),
    ],
    dependencies: [
        .package(name: "AriaMcpKit", path: "../../packages/kits/AriaMcpKit"),
    ],
    targets: [
        .target(
            name: "MootCommunityGateway",
            dependencies: [
                .product(name: "AriaMCPWire", package: "AriaMcpKit"),
            ],
            path: "Sources/MootCommunityGateway"
        ),
        .target(
            name: "MootCommunityUI",
            dependencies: ["MootCommunityGateway"],
            path: "Sources/MootCommunityUI"
        ),
        .testTarget(
            name: "CommunityBoundaryTests",
            dependencies: ["MootCommunityUI", "MootCommunityGateway"],
            path: "Tests/CommunityBoundaryTests"
        ),
    ]
)
