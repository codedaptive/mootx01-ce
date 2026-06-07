// swift-tools-version: 6.2
//
// EideticLib. A deterministic text-to-anchor utility: pass a term,
// get back an FDC code and the dominant concept's Wikidata Q-ID,
// resolved through LatticeLib's FDC engine. Pure Swift, conformance-
// gated against the Rust port at rust/.
//
// EideticLib is a peer of the MOOTx01 substrate kits, not a member
// of them. NeuronKit depends on EideticLib; EideticLib depends on
// LatticeLib (the FDC engine and shared text primitives) and on no
// other kit.

import PackageDescription

let package = Package(
    name: "EideticLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "EideticLib",
            targets: ["EideticLib"]
        ),
    ],
    dependencies: [
        .package(path: "../LatticeLib"),
    ],
    targets: [
        .target(
            name: "EideticLib",
            dependencies: [
                .product(name: "LatticeLib", package: "LatticeLib"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "EideticLibTests",
            dependencies: [
                "EideticLib",
                .product(name: "LatticeLib", package: "LatticeLib"),
            ],
            resources: [
                .copy("../SharedVectors"),
            ]
        ),
    ]
)
