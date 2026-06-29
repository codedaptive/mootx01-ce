// swift-tools-version:6.0
//
// Package.swift — GeniusLocus reference Swift library.
//
// The glref-swift-*.swift files in this directory compile as
// a single library target named GeniusLocusReference. Filenames
// keep the glref-swift- prefix for cookbook cross-reference; the
// public types they export are visible under the
// `GeniusLocusReference` module.

import PackageDescription

let package = Package(
    name: "GeniusLocusReference",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "GeniusLocusReference",
            targets: ["GeniusLocusReference"]
        ),
    ],
    targets: [
        .target(
            name: "GeniusLocusReference",
            path: ".",
            exclude: ["Package.swift"]
        ),
    ]
)
