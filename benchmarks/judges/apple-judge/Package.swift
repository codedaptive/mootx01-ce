// swift-tools-version:6.0
// apple-judge — a --judge-cmd backend over Apple's bundled on-device
// model (FoundationModels). Ships with the public benchmark tool as
// one of the two local judges (ruling 2026-08-05). Standalone package
// so it builds without the harness and vice versa.
import PackageDescription

let package = Package(
    name: "apple-judge",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "apple-judge", path: "Sources/apple-judge")
    ]
)
