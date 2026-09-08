// swift-tools-version:6.2
//
// Package.swift — MootProductIdentity
//
// The one place the product says who it is on disk and in logs. Every kit
// and app that needs the Application Support folder name, the logging
// subsystem, or a bundle identifier reads it from here instead of spelling
// its own copy. Foundation library: no dependencies, so every package can
// import it without inverting layering.
//
// Pinned to Fixtures/product_identity.json by a conformance test. No Rust
// twin exists yet; the Rust port builds one against the same fixture when its
// estate catalog lands.
import PackageDescription

let package = Package(
    name: "MootProductIdentity",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "MootProductIdentity", targets: ["MootProductIdentity"]),
    ],
    targets: [
        .target(
            name: "MootProductIdentity",
            path: "Sources/MootProductIdentity"
        ),
        .testTarget(
            name: "MootProductIdentityTests",
            dependencies: ["MootProductIdentity"],
            path: "Tests/MootProductIdentityTests",
            resources: [.copy("../../Fixtures/product_identity.json")]
        ),
    ]
)
