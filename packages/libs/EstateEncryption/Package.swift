// swift-tools-version:6.2
import PackageDescription

// EstateEncryption — the plaintext-to-encrypted estate conversion, standalone.
//
// One implementation, two consumers: the product (`mootx01 upgrade`) and the
// benchmark harness. It was previously inside MootInstallerCore, which put it
// above the layer both consumers can reach and left the Rust port to carry a
// second, divergent copy.
//
// The Swift and Rust ports of this library are the same shape: same names,
// same types, same field sets, same failure semantics. A defect here is
// isolated to this library and fixed once per port.
let package = Package(
    name: "EstateEncryption",
    // Matches the SQLCipher product's floor.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "EstateEncryption", targets: ["EstateEncryption"]),
    ],
    dependencies: [
        .package(name: "PersistenceKit", path: "../../kits/PersistenceKit"),
    ],
    targets: [
        .target(
            name: "EstateEncryption",
            dependencies: [
                .product(name: "SQLCipher", package: "PersistenceKit"),
            ],
            path: "Sources/EstateEncryption"),
        .testTarget(
            name: "EstateEncryptionTests",
            dependencies: ["EstateEncryption"],
            path: "Tests/EstateEncryptionTests"),
    ]
)
