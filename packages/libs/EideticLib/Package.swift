// swift-tools-version: 6.0
//
// EideticLib. A deterministic text-to-anchor utility: pass a term,
// get back an MDCC code (resolved against the bundled MDCC canon
// from LatticeLib) and the canon entry's Wikidata Q-ID. Pure Swift,
// conformance-gated against the Rust port at rust/.
//
// EideticLib is a peer of the MOOTx01 substrate kits, not a member
// of them. NeuronKit depends on EideticLib; EideticLib depends on
// LatticeLib (the CC0/public-domain MDCC canon) and on no other kit.
// The bundled classification data is CC0/MDCC only — no foreign-
// licensed (CC-BY-SA) corpus ships in this package.

import PackageDescription

let package = Package(
    name: "EideticLib",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
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
