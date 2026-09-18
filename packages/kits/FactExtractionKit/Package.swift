// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "FactExtractionKit",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "FactExtractionKit", targets: ["FactExtractionKit"]),
        .library(name: "FactExtractionKitProviders", targets: ["FactExtractionKitProviders"]),
    ],
    targets: [
        .target(
            name: "FactExtractionKit",
            path: "Sources/FactExtractionKit"
        ),
        .target(
            name: "FactExtractionKitProviders",
            dependencies: ["FactExtractionKit"],
            path: "Sources/FactExtractionKitProviders"
        ),
        .testTarget(
            name: "FactExtractionKitTests",
            dependencies: ["FactExtractionKit", "FactExtractionKitProviders"],
            path: "Tests/FactExtractionKitTests"
        ),
    ]
)
